#!/usr/bin/env bash
# cost-sentinel.sh — find AWS resources that bill by the hour, in every region.
#
# This is deliberately NOT a teardown script. It deletes nothing. The thing that
# produces a surprise bill is usually a resource nobody remembers creating, in a
# region nobody thinks to look at — a teardown script only removes what you
# already know about, and goes stale the moment you add a resource it has never
# heard of.
#
# Read-only. Exits 1 if anything billable is found, 0 if the account is clean,
# so it can gate a scheduled job.
#
# Costs below are rough us-east-1 on-demand figures for orientation only. They
# are not a quote, they ignore data transfer, and they vary by region.

set -uo pipefail

# Regions to sweep. Enumerated live where permitted; otherwise a static list of
# the regions enabled by default on a new account. The fallback matters: if
# DescribeRegions is denied and we silently swept only one region, this would
# report "clean" while missing everything. A sentinel that fails quiet is worse
# than no sentinel.
REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null || true)
if [ -z "$REGIONS" ]; then
  echo "note: ec2:DescribeRegions denied — falling back to the default region list" >&2
  REGIONS="us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-west-2 eu-west-3 \
eu-central-1 eu-north-1 ap-south-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 \
ap-northeast-2 ap-northeast-3 ca-central-1 sa-east-1"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Query one service in one region. Any AccessDenied is recorded as UNKNOWN
# rather than treated as "nothing found" — not being allowed to look is not
# the same as there being nothing there.
probe() {
  local region=$1 label=$2 cost=$3
  shift 3
  local out rc
  out=$("$@" --region "$region" --output text 2>"$WORK/err.$region.$label")
  rc=$?
  if [ $rc -ne 0 ]; then
    if grep -qiE "AccessDenied|UnauthorizedOperation|not authorized" "$WORK/err.$region.$label"; then
      echo "UNKNOWN|$region|$label|permission denied" >> "$WORK/findings.$region"
    fi
    # Other errors (region disabled, endpoint unreachable) are not findings.
    return
  fi
  [ -z "$out" ] || [ "$out" = "None" ] && return
  local n
  n=$(echo "$out" | tr '\t' '\n' | grep -c . || true)
  [ "$n" -eq 0 ] && return
  echo "BILLABLE|$region|$label|$n found — approx $cost" >> "$WORK/findings.$region"
}

sweep_region() {
  local r=$1

  probe "$r" "NAT gateway" '$32/mo each' \
    aws ec2 describe-nat-gateways \
    --filter Name=state,Values=available,pending \
    --query 'NatGateways[].NatGatewayId'

  probe "$r" "EC2 instance (running)" '$8-250/mo each' \
    aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId'

  # Every allocated Elastic IP now bills, attached or not.
  probe "$r" "Elastic IP" '$3.60/mo each' \
    aws ec2 describe-addresses \
    --query 'Addresses[].AllocationId'

  probe "$r" "Load balancer" '$16-22/mo each' \
    aws elbv2 describe-load-balancers \
    --query 'LoadBalancers[].LoadBalancerName'

  probe "$r" "RDS instance" '$13-200/mo each' \
    aws rds describe-db-instances \
    --query 'DBInstances[].DBInstanceIdentifier'

  # Detached volumes keep billing for provisioned capacity.
  probe "$r" "Unattached EBS volume" '$0.08/GB/mo' \
    aws ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[].VolumeId'

  # Interface endpoints bill hourly; Gateway endpoints (S3, DynamoDB) are free,
  # so only Interface ones are counted.
  probe "$r" "VPC interface endpoint" '$7/mo each' \
    aws ec2 describe-vpc-endpoints \
    --filters Name=vpc-endpoint-type,Values=Interface \
    --query 'VpcEndpoints[].VpcEndpointId'

  probe "$r" "EKS cluster" '$73/mo each' \
    aws eks list-clusters --query 'clusters'
}

echo "Sweeping $(echo "$REGIONS" | wc -w | tr -d ' ') regions as $(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)"
echo

# Regions run in parallel; a serial sweep of ~17 regions is slow enough that
# people stop running it.
for r in $REGIONS; do sweep_region "$r" & done
wait

# grep -c prints 0 and exits 1 when nothing matches, so `|| echo 0` would append
# a SECOND zero and break the integer comparisons below. Take grep's output and
# default only when the file is absent entirely.
cat "$WORK"/findings.* > "$WORK/findings" 2>/dev/null || true
billable=$(grep -c '^BILLABLE' "$WORK/findings" 2>/dev/null)
unknown=$(grep -c '^UNKNOWN' "$WORK/findings" 2>/dev/null)
billable=${billable:-0}
unknown=${unknown:-0}

if [ "$billable" -gt 0 ]; then
  echo "BILLABLE RESOURCES FOUND"
  echo
  printf '%-16s %-26s %s\n' REGION RESOURCE DETAIL
  printf '%-16s %-26s %s\n' ---------------- -------------------------- ------
  grep '^BILLABLE' "$WORK/findings" | sort -t'|' -k2,2 \
    | while IFS='|' read -r _ region label detail; do
        printf '%-16s %-26s %s\n' "$region" "$label" "$detail"
      done
  echo
fi

if [ "$unknown" -gt 0 ]; then
  echo "COULD NOT CHECK (permission denied — treat as unknown, not clean)"
  echo
  # Grouped by resource type with a region count: a denial is almost always the
  # same missing IAM action in every region, and listing one arbitrary region
  # would imply the others were checked and found clean.
  grep '^UNKNOWN' "$WORK/findings" | cut -d'|' -f3 | sort | uniq -c \
    | while read -r count label; do
        printf '  %-26s denied in %s region(s)\n' "$label" "$count"
      done
  echo
fi

if [ "$billable" -eq 0 ] && [ "$unknown" -eq 0 ]; then
  echo "Clean — no hourly-billing resources found in any region."
  exit 0
fi

if [ "$billable" -eq 0 ]; then
  echo "No billable resources found, but some checks could not run."
  exit 0
fi

echo "A budget alert is the backstop this script cannot replace:"
echo "  Billing -> Budgets -> Create budget"
exit 1
