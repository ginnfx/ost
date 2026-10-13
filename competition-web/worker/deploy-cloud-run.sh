#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:?Set GCP_REGION}"
: "${GCP_ARTIFACT_REPOSITORY:?Set GCP_ARTIFACT_REPOSITORY}"
: "${GCP_TASKS_CLIENT_EMAIL:?Set the Cloud Tasks enqueuer service-account email}"
: "${GCP_TASKS_INVOKER_SERVICE_ACCOUNT:?Set the Cloud Run invoker service-account email}"
: "${MEDIA_WORKER_RUNTIME_SERVICE_ACCOUNT:?Set the Cloud Run runtime service-account email}"
: "${MEDIA_ALLOWED_STORAGE_ORIGIN:?Set to the Supabase project origin}"
: "${MEDIA_CALLBACK_ORIGIN:?Set to the permanent website origin}"

gcloud config set project "${GCP_PROJECT_ID}"
image="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${GCP_ARTIFACT_REPOSITORY}/media-worker:$(git rev-parse --short HEAD)"
gcloud builds submit --project "${GCP_PROJECT_ID}" --tag "${image}" worker

gcloud secrets add-iam-policy-binding ost-media-worker-callback \
  --project "${GCP_PROJECT_ID}" \
  --member "serviceAccount:${MEDIA_WORKER_RUNTIME_SERVICE_ACCOUNT}" \
  --role roles/secretmanager.secretAccessor

gcloud run deploy ost-media-worker \
  --project "${GCP_PROJECT_ID}" \
  --region "${GCP_REGION}" \
  --image "${image}" \
  --service-account "${MEDIA_WORKER_RUNTIME_SERVICE_ACCOUNT}" \
  --no-allow-unauthenticated \
  --min 0 --max 3 --concurrency 1 \
  --cpu 2 --memory 2Gi --timeout 1800s \
  --set-env-vars "NODE_ENV=production,MEDIA_ALLOWED_STORAGE_ORIGIN=${MEDIA_ALLOWED_STORAGE_ORIGIN},MEDIA_CALLBACK_ORIGIN=${MEDIA_CALLBACK_ORIGIN},MEDIA_TASK_MAX_ATTEMPTS=5,MEDIA_WORKER_TIMEOUT_SECONDS=900" \
  --set-secrets "MEDIA_WORKER_CALLBACK_SECRET=ost-media-worker-callback:latest"

gcloud run services add-iam-policy-binding ost-media-worker \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" \
  --member "serviceAccount:${GCP_TASKS_INVOKER_SERVICE_ACCOUNT}" \
  --role roles/run.invoker

gcloud iam service-accounts add-iam-policy-binding "${GCP_TASKS_INVOKER_SERVICE_ACCOUNT}" \
  --project "${GCP_PROJECT_ID}" \
  --member "serviceAccount:${GCP_TASKS_CLIENT_EMAIL}" \
  --role roles/iam.serviceAccountUser

