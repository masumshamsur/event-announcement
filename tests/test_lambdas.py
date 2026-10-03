"""Unit tests for both Lambda handlers, run against in-memory fakes of S3 and SNS.

No AWS account or boto3 install needed:  python3 tests/test_lambdas.py
"""
import importlib.util
import io
import json
import os
import sys
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------- Fake boto3 / botocore ----------

class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeS3:
    def __init__(self):
        self.body, self.etag, self.puts, self.fail_next_put = None, None, [], False

    def get_object(self, Bucket, Key):
        if self.body is None:
            raise ClientError("NoSuchKey")
        return {"Body": io.BytesIO(self.body), "ETag": self.etag}

    def put_object(self, **kwargs):
        if self.fail_next_put:  # simulate another writer changing the file mid-request
            self.fail_next_put = False
            self.etag = '"changed-by-someone-else"'
            raise ClientError("PreconditionFailed")
        if "IfMatch" in kwargs:
            assert kwargs["IfMatch"] == self.etag, "conditional write used a stale ETag"
        self.puts.append(kwargs)
        self.body = kwargs["Body"]
        self.etag = f'"{len(self.puts)}"'


class FakeSNS:
    def __init__(self):
        self.calls = []

    def subscribe(self, **kwargs):
        self.calls.append(("subscribe", kwargs))

    def publish(self, **kwargs):
        self.calls.append(("publish", kwargs))


s3, sns = FakeS3(), FakeSNS()
botocore_exceptions = types.ModuleType("botocore.exceptions")
botocore_exceptions.ClientError = ClientError
sys.modules["botocore"] = types.ModuleType("botocore")
sys.modules["botocore.exceptions"] = botocore_exceptions
fake_boto3 = types.ModuleType("boto3")
fake_boto3.client = lambda name: {"s3": s3, "sns": sns}[name]
sys.modules["boto3"] = fake_boto3
os.environ.update(SNS_TOPIC_ARN="arn:aws:sns:us-east-1:000000000000:test", BUCKET_NAME="test-bucket")


def load(relpath):
    path = os.path.join(ROOT, relpath)
    spec = importlib.util.spec_from_file_location(relpath, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request(body):
    return {"body": json.dumps(body), "requestContext": {"http": {"method": "POST"}}}


subscribe = load("lambdas/subscribe/lambda_function.py")
create_event = load("lambdas/create_event/lambda_function.py")


# ---------- Tests ----------

def test_subscribe_valid_email():
    r = subscribe.lambda_handler(request({"email": "A@b.co"}), None)
    assert r["statusCode"] == 200, r
    assert sns.calls[-1] == ("subscribe", {
        "TopicArn": os.environ["SNS_TOPIC_ARN"], "Protocol": "email",
        "Endpoint": "a@b.co", "ReturnSubscriptionArn": True,
    })


def test_subscribe_rejects_bad_input():
    assert subscribe.lambda_handler(request({"email": "not-an-email"}), None)["statusCode"] == 400
    assert subscribe.lambda_handler({"body": "{bad json"}, None)["statusCode"] == 400


def test_create_event_first_write_and_notify():
    good = {"title": "Meetup", "date": "2026-12-01", "description": "Talks"}
    r = create_event.lambda_handler(request(good), None)
    assert r["statusCode"] == 200, r
    assert s3.puts[-1]["IfNoneMatch"] == "*"  # file didn't exist yet
    assert len(json.loads(s3.body)) == 1
    kind, msg = sns.calls[-1]
    assert kind == "publish" and "When: Tuesday, December 01, 2026" in msg["Message"]


def test_create_event_retries_on_concurrent_write():
    s3.fail_next_put = True
    good = {"title": "Second", "date": "2026-12-02", "description": "More talks"}
    r = create_event.lambda_handler(request(good), None)
    assert r["statusCode"] == 200, r
    events = json.loads(s3.body)
    assert [e["title"] for e in events] == ["Meetup", "Second"]
    assert "IfMatch" in s3.puts[-1]


def test_create_event_rejects_bad_input():
    good = {"title": "T", "date": "2026-12-01", "description": "D"}
    assert create_event.lambda_handler(request({**good, "date": "12/01/2026"}), None)["statusCode"] == 400
    assert create_event.lambda_handler(request({"title": "T"}), None)["statusCode"] == 400
    assert create_event.lambda_handler(request([1]), None)["statusCode"] == 400


if __name__ == "__main__":
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_")]
    for name, fn in tests:
        fn()
        print(f"PASS  {name}")
    print(f"\n{len(tests)} tests passed")
