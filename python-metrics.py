import gitlab
import pandas as pd
import urllib3
import os
from collections import defaultdict

# ==============================
# DISABLE SSL WARNINGS
# ==============================

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ==============================
# CONFIGURATION
# ==============================

GITLAB_URL = os.getenv("GITLAB_URL")
ACCESS_TOKEN = os.getenv("GITLAB_TOKEN")

# Deployment patterns
TARGET_PATTERNS = {
    "openshift": ["ose:deploy"],
    "lambda": ["lambda:"],
    "ecs": ["ecs:downstream"],
    "ansible": ["ansible:"],
    "database": ["database:"],
    "migration": ["migrate:"],
    "infra_version": ["infra:version"]
}

# ==============================
# CONNECT TO GITLAB
# ==============================

gl = gitlab.Gitlab(
    GITLAB_URL,
    private_token=ACCESS_TOKEN,
    ssl_verify=False
)

print("Connected to GitLab")

projects = gl.projects.list(all=True)

group_counts = defaultdict(int)
language_counts = defaultdict(int)
infra_counts = defaultdict(int)

metrics_rows = []

print(f"Projects discovered: {len(projects)}")

# ==============================
# PROCESS PROJECTS
# ==============================

for project in projects:

    try:
        project_detail = gl.projects.get(project.id)

        topics = project_detail.topics or []
        apm_id = None

        for topic in topics:
            if topic.lower().startswith("apm"):
                apm_id = topic

        if not apm_id:
            continue

        group_name = project_detail.namespace["name"]
        group_counts[apm_id] += 1

        # -----------------------
        # LANGUAGE METRICS
        # -----------------------

        try:
            languages = project_detail.languages()

            for lang in languages:
                language_counts[lang] += 1
        except:
            pass

        # -----------------------
        # PIPELINE METRICS
        # -----------------------

        try:
            pipelines = project_detail.pipelines.list(per_page=20)

            for pipeline in pipelines:

                pipeline_detail = project_detail.pipelines.get(pipeline.id)
                jobs = pipeline_detail.jobs.list()

                for job in jobs:
                    job_name = job.name.lower()

                    for infra, patterns in TARGET_PATTERNS.items():
                        for p in patterns:
                            if job_name.startswith(p):
                                infra_counts[infra] += 1

        except:
            pass

        metrics_rows.append({
            "project": project_detail.name,
            "apm_id": apm_id,
            "group": group_name
        })

    except Exception as e:
        print(f"Error processing project {project.id}: {e}")


# ==============================
# EXPORT METRICS
# ==============================

df_groups = pd.DataFrame(list(group_counts.items()), columns=["APM_ID", "Project_Count"])
df_lang = pd.DataFrame(list(language_counts.items()), columns=["Language", "Repo_Count"])
df_infra = pd.DataFrame(list(infra_counts.items()), columns=["Target_Infra", "Pipeline_Count"])

df_groups.to_csv("groups_by_apm.csv", index=False)
df_lang.to_csv("repos_by_language.csv", index=False)
df_infra.to_csv("pipelines_by_target_infra.csv", index=False)

print("Metrics generated successfully")