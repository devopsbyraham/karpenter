Someone with admin rights (CloudShell or the console) saves the attached karpenter-installer-policy.json. It is already filled in for account xxxxxxxx, cluster raham-cluster-1 and region ap-southeast-1.
They attach it to the bastion’s role:
   aws iam put-role-policy --role-name raham-cluster-1-bastion-server-role-eks \
     --policy-name KarpenterInstaller \
     --policy-document file://karpenter-installer-policy.json
Back on the bastion, run the dry run first, then the real run:
   CLUSTER_NAME=raham-cluster-1 AWS_REGION=ap-southeast-1 ./karpenter-eks-setup.sh --dry-run
   CLUSTER_NAME=raham-cluster-1 AWS_REGION=ap-southeast-1 ./karpenter-eks-setup.sh
