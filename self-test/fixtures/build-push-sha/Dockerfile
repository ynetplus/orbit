# Dummy Dockerfile fixture for self-test.yml's build-push-sha-contract job.
# Builds locally only (no push, no ECR, no AWS credentials) — proves the
# Dockerfile/context leg of build-push-sha.yml's contract without touching
# real infrastructure. Not a real product image; never pushed anywhere.
FROM alpine:3.19
CMD ["true"]
