aws sagemaker create-image-version \
  --image-name <your-sagemaker-image-name> \
  --base-image <account>.dkr.ecr.<region>.amazonaws.com/<repo>:soci_indexed


MANIFEST=$(aws ecr batch-get-image --repository-name <repo> \
  --image-ids imageTag=soci_indexed \
  --query 'images[0].imageManifest' --output text)
aws ecr put-image --repository-name <repo> \
  --image-tag jupyterlab-uat \
  --image-manifest "$MANIFEST"
