#!/usr/bin/env python3
"""
FinCorp architecture diagrams.

Run from the project root:
    python diagram-engine-room/main.py

Outputs (written to docs/):
    fincorp_pipeline.png  -- Workstream A: Immutable Artifact Pipeline
    fincorp_dr.png        -- Workstream B: Cross-Region Disaster Recovery
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, ECS
from diagrams.aws.database import RDS
from diagrams.aws.devtools import Codeartifact
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import ALB
from diagrams.aws.security import IAM
from diagrams.aws.storage import Backup
from diagrams.onprem.client import Users
from diagrams.onprem.vcs import Github

# -- Output directory ----------------------------------------------------------
OUT = Path(__file__).parent.parent / "docs"
OUT.mkdir(exist_ok=True)

# -- Shared graph attributes ---------------------------------------------------
BASE_GRAPH = {
    "splines": "ortho",
    "fontname": "Helvetica",
    "fontsize": "14",
    "pad": "1.2",
    "bgcolor": "white",
    "dpi": "150",
}

AWS_REGION = {
    "bgcolor": "#EBF5FF",
    "style": "rounded",
    "fontname": "Helvetica Bold",
    "fontsize": "13",
    "margin": "24",
}
DR_REGION = {
    "bgcolor": "#FFF8E1",
    "style": "rounded",
    "fontname": "Helvetica Bold",
    "fontsize": "13",
    "margin": "24",
}
INNER = {
    "bgcolor": "#FAFEFF",
    "style": "rounded",
    "fontname": "Helvetica",
    "fontsize": "12",
    "margin": "16",
}
EXTERNAL = {
    "bgcolor": "#F5F5F5",
    "style": "rounded",
    "fontname": "Helvetica",
    "fontsize": "12",
    "margin": "16",
}


# ==============================================================================
# Diagram 1 -- Workstream A: Immutable Artifact Pipeline
#
# direction="TB" (top-to-bottom).
#
# Edge design rules to produce clean ortho routing:
#   1. CodeArtifact is chained INTO the build (ca_pip >> ecr_dev) rather than
#      being a direct target from GitHub -- eliminates skip edges.
#   2. Traffic direction is ECS >> ALB >> end_users (not reversed), so End Users
#      land at the BOTTOM rank instead of floating to the top.
#   3. IAM is a dashed side channel from GitHub -- no outgoing edges so it
#      becomes a leaf and does not affect main trunk ranks.
# ==============================================================================
with Diagram(
    "FinCorp -- Workstream A: Immutable Artifact Pipeline",
    show=False,
    direction="LR",
    filename=str(OUT / "fincorp_pipeline"),
    graph_attr={**BASE_GRAPH, "nodesep": "0.8", "ranksep": "1.6",
                "size": "22,14", "ratio": "fill"},
):
    developer = Users("Developer")

    with Cluster("GitHub  (external)", graph_attr=EXTERNAL):
        gh_ci = Github("GitHub Actions\nCI  /  CD")

    with Cluster("AWS   eu-west-1  (Ireland)", graph_attr=AWS_REGION):

        # OIDC side-channel -- leaf node, does not affect pipeline rank ordering
        iam = IAM("OIDC Role\ngithub-actions-fincorp")

        # Single CodeArtifact node -- the public:pypi upstream is an internal
        # CodeArtifact implementation detail, not a separate architecture component.
        # Collapsing to one node gives it an incoming edge from GitHub, placing it
        # at rank 2 (after GitHub) and keeping the AWS cluster to the right of the
        # external nodes in LR layout.
        with Cluster("AWS CodeArtifact", graph_attr=INNER):
            ca_pip = Codeartifact("fincorp-pip\n(proxies public:pypi)")

        with Cluster("Amazon ECR", graph_attr=INNER):
            ecr_dev  = ECR("fincorp-api-dev\nIMMUTABLE | scan on push")
            ecr_prod = ECR("fincorp-api-prod\nIMMUTABLE | scan on push")

        with Cluster("ECS Fargate", graph_attr=INNER):
            ecs_dev  = ECS("fincorp-api-dev\nauto-deploy")
            ecs_prod = ECS("fincorp-api-prod\nmanual approval")

        alb = ALB("Application\nLoad Balancer")
        cw  = Cloudwatch("CloudWatch\nContainer Insights")

    end_users = Users("End Users")

    # -- Main pipeline trunk: Developer -> GitHub -> CodeArtifact -> ECR -> ECS
    developer >> Edge(label="git push  main", color="#555555") >> gh_ci

    # OIDC authentication (leaf -- no outgoing edges keeps it off the main trunk)
    gh_ci >> Edge(label="OIDC token", color="seagreen", style="dashed") >> iam

    # GitHub resolves pip deps from CodeArtifact, builds the Docker image,
    # and pushes to ECR -- all in one CI job. Chaining via ca_pip keeps
    # CodeArtifact at rank 2 and ECR at rank 3: no skip edges from GitHub.
    gh_ci  >> Edge(label="pip install\n(short-lived token)", color="steelblue") >> ca_pip
    ca_pip >> Edge(label="docker build + push\n(git SHA tag)", color="darkorange") >> ecr_dev

    # ECR scans on push; pipeline fails on HIGH or CRITICAL CVE
    ecr_dev >> Edge(label="CVE gate passed\nauto-deploy", color="seagreen") >> ecs_dev

    # Manual promotion via GitHub Environment reviewer gate
    ecr_dev  >> Edge(label="promote +\nreviewer approval", color="darkorange", style="dashed") >> ecr_prod
    ecr_prod >> Edge(label="prod  deploy", color="seagreen") >> ecs_prod

    # ECS exposes service through ALB to end users (ECS >> ALB >> users keeps
    # users at the bottom rank, not floating to the top as with users >> ALB)
    ecs_dev  >> alb
    ecs_prod >> alb
    alb >> Edge(label="HTTPS") >> end_users

    # Observability side-channel
    ecs_dev  >> Edge(color="#AAAAAA", style="dashed") >> cw
    ecs_prod >> Edge(color="#AAAAAA", style="dashed") >> cw


# ==============================================================================
# Diagram 2 -- Workstream B: Cross-Region Disaster Recovery
# ==============================================================================
with Diagram(
    "FinCorp -- Workstream B: Cross-Region Disaster Recovery",
    show=False,
    direction="LR",
    filename=str(OUT / "fincorp_dr"),
    graph_attr={**BASE_GRAPH, "nodesep": "1.2", "ranksep": "2.0"},
):
    with Cluster("Primary Region -- eu-west-1  (Ireland)", graph_attr=AWS_REGION):

        with Cluster("VPC -- Private Subnets", graph_attr=INNER):
            rds_primary = RDS(
                "fincorp-postgres\n"
                "PostgreSQL 16\n"
                "encrypted at rest"
            )

        with Cluster("AWS Backup -- Primary Vault", graph_attr=INNER):
            vault_primary = Backup(
                "fincorp-primary-vault\n"
                "7-day retention"
            )

    with Cluster("DR Region -- eu-central-1  (Frankfurt)", graph_attr=DR_REGION):

        with Cluster("AWS Backup -- DR Vault", graph_attr=INNER):
            vault_dr = Backup(
                "fincorp-dr-vault\n"
                "14-day retention"
            )

        with Cluster("VPC -- Private Subnets", graph_attr=INNER):
            rds_dr = RDS(
                "fincorp-postgres-dr\n"
                "PostgreSQL 16\n"
                "(restored instance)"
            )

    rds_primary >> Edge(
        label="daily snapshot\n@ 02:00 UTC\n(tag: DR=true)",
        color="steelblue",
    ) >> vault_primary

    # copy_action in the Backup plan triggers automatic cross-region replication
    vault_primary >> Edge(
        label="cross-region copy\n(copy_action)\neu-west-1 -> eu-central-1",
        color="darkorange",
        style="bold",
    ) >> vault_dr

    # On failure: operator runs start-restore-job targeting the DR vault
    vault_dr >> Edge(
        label="aws backup\nstart-restore-job\nRTO target < 30 min",
        color="seagreen",
        style="dashed",
    ) >> rds_dr


print(f"Diagrams written to: {OUT}/")
print("  fincorp_pipeline.png")
print("  fincorp_dr.png")
