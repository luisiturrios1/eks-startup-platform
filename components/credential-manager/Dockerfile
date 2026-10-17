#checkov:skip=CKV_DOCKER_2:AWS Lambda supervises the runtime and invocation health; Docker HEALTHCHECK is not used for Lambda container images. See docs/security-exceptions.md.
FROM public.ecr.aws/lambda/python:3.12@sha256:3856536f53e945debf4c90d0ff301cbaa837c07a4ab9b0e2c102c6e54ceb9762
COPY requirements.txt ${LAMBDA_TASK_ROOT}/requirements.txt
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt
COPY handler.py ${LAMBDA_TASK_ROOT}/handler.py
# RDS CA trust bundle is verified and downloaded by scripts/prepare-assets.sh.
COPY global-bundle.pem ${LAMBDA_TASK_ROOT}/global-bundle.pem
USER 10001:10001
CMD ["handler.handler"]
