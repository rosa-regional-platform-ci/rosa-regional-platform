# Provision a New Hosted Cluster

## Prerequisites

### ROSA Regional Platform CLI

```bash
# Clone the repository
git clone https://github.com/openshift-online/rosa-regional-platform-cli.git
cd rosa-regional-platform-cli

# Build
make build

# Install globally (optional)
make install
```

### Dependencies

```bash
command -v jq >/dev/null || echo "Need jq installed"
command -v awscurl >/dev/null || echo "Need awscurl installed"
```

- [awscurl](https://github.com/okigan/awscurl)

## Set AWS account

```bash
# assume role into the "customer" account
# you can create hcp from any aws account, but just to ensure separation
# you can use a separate account to mimic a customer workflow. Set this
# to be any AWS profile to an account you have access to.
export AWS_PROFILE=rrp-customer-dev
```

## Using the rosactl command

### Gather Data

```bash
# 1. Get the API_URL, this is output as part of your ephemeral environment or use integration
# Example raw ephemeral API Gateway URL:
# API_URL=https://ra15lectz3.execute-api.us-east-1.amazonaws.com/prod
# or use our integration env
API_URL=https://api.int0.rosa.devshift.net

# 2. Set your Cluster Variables
REGION=us-east-1
AZ=${REGION}a
CLUSTER_NAME=
```

<details>
  <summary>Ensure your AWS Account is allowlisted in the environment (only needs to be run once per environment)</summary>

> This only needs to be run once per environment. If you have already run this, feel free to unfold this section and skip to the next step.

#### Ephemeral Environment

```bash
# 1. Get your account ID:
ACCOUNT=$(aws sts get-caller-identity | jq -r .Account)

# 2. For ephemeral envs, log into the bastion for the RC and run - reusing the variables from above:

#helper output to give you all the variables again if they've scrolled out of view:
echo "ACCOUNT=${ACCOUNT} REGION=${REGION} API_URL=${API_URL}"

# Connect to the RC
make ephemeral-bastion-rc

# You'll probably need to install awscurl the first time:
pip install awscurl

# Paste the output from the `echo` command above into the bastion session to set the env vars, and then run:
awscurl --service execute-api --region "${REGION}" -X POST "${API_URL}/api/v0/accounts" -H "Content-Type: application/json" -d "{\"accountId\": \"${ACCOUNT}\", \"privileged\": true}"
```

#### Integration/Staging Environments

Have an already-privileged user allow your account. Provide your account to the user, and then they run:

```bash
ACCOUNT=
API_URL=https://api.int0.rosa.devshift.net
REGION=us-east-1
awscurl --service execute-api --region "${REGION}" -X POST "${API_URL}/api/v0/accounts" -H "Content-Type: application/json" -d "{\"accountId\": \"${ACCOUNT}\", \"privileged\": true}"
```

---

</details>

```bash
# 1. set the reference to the platform api
rosactl login --url $API_URL

# 1. setup iam in the customer account (via cloudformation stack)
rosactl cluster-iam create $CLUSTER_NAME --region $REGION

# 2. setup vpc for the hosted cluster. Currently, we only support HCP with 1 az.
# (also cloudformation stack)
rosactl cluster-vpc create $CLUSTER_NAME --region $REGION --availability-zones $AZ

# 3. submit the cluster creation to the platform api
# --placement (required only in ephemeral environment)
PLACEMENT=$(awscurl --service execute-api $API_URL/api/v0/management_clusters | jq -r '.items[0].name')

rosactl cluster create $CLUSTER_NAME --region $REGION --placement $PLACEMENT | tee /tmp/$CLUSTER_NAME.json

# export CLOUDURL with the value of cloudUrl in the response above
CLOUDURL=$(jq -r '.spec.cloudUrl' < /tmp/$CLUSTER_NAME.json)

# 4. create the oidc for the hcp
rosactl cluster-oidc create $CLUSTER_NAME --region $REGION --oidc-issuer-url $CLOUDURL
```

# Notes

1. if you create more than 5 hcp, make sure your account has more than nat gateway quota. The default is 5.
