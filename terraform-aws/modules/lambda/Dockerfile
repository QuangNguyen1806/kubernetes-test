# Lambda container image (AWS Lambda Python 3.12 base).
# Build for linux/amd64 so it runs on Lambda regardless of host arch.
FROM public.ecr.aws/lambda/python:3.12

COPY handler.py ${LAMBDA_TASK_ROOT}/

# handler.handler → module "handler", function "handler"
CMD ["handler.handler"]
