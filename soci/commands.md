aws sagemaker create-image-version \
  --image-name <your-sagemaker-image-name> \
  --base-image <account>.dkr.ecr.<region>.amazonaws.com/<repo>:soci_indexed


MANIFEST=$(aws ecr batch-get-image --repository-name <repo> \
  --image-ids imageTag=soci_indexed \
  --query 'images[0].imageManifest' --output text)
aws ecr put-image --repository-name <repo> \
  --image-tag jupyterlab-uat \
  --image-manifest "$MANIFEST"



ACCOUNT_ID="<your-account>"
REGION="ap-southeast-2"
REPO="sagemaker-distribution"
SOCI_TAG="soci_indexed"
SM_IMAGE_NAME="<your-sagemaker-image-name>"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO:$SOCI_TAG"


aws ecr describe-images --repository-name $REPO --region $REGION \
  --image-ids imageTag=$SOCI_TAG \
  --query 'imageDetails[0].imageManifestMediaType' --output text
# expect: application/vnd.oci.image.index.v1+json


aws ecr describe-images --repository-name $REPO --region $REGION \
  --image-ids imageTag=$SOCI_TAG \
  --query 'imageDetails[0].imageDigest' --output text

# list existing versions
aws sagemaker list-image-versions --image-name $SM_IMAGE_NAME --region $REGION \
  --query 'ImageVersions[].Version' --output text
# delete a given version number
aws sagemaker delete-image-version --image-name $SM_IMAGE_NAME --version <N> --region $REGION


aws sagemaker create-image-version \
  --image-name $SM_IMAGE_NAME \
  --base-image $ECR_URI \
  --region $REGION

aws sagemaker describe-image-version --image-name $SM_IMAGE_NAME --region $REGION \
  --query 'ImageVersionStatus' --output text
# poll until: CREATED  (not CREATING; CREATE_FAILED means delete and investigate)


aws sagemaker describe-image-version --image-name $SM_IMAGE_NAME --region $REGION \
  --query 'ContainerImage' --output text
# the part after @sha256: should equal the digest from step 2
