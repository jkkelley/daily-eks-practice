# Daily EKS Practice - lifecycle Makefile (Linux + Windows 11).
# Config-driven: every value comes from scripts/config.toml via scripts/bootstrap.py.
# Testing lives in Makefile.test.
#
#   make up                    # generate tfvars from config, then init + apply
#   make plan
#   make kubeconfig            # point kubectl at the cluster
#   make git-seed              # publish this repo into the in-cluster git server
#   make app-deploy            # hand the practice app to Argo CD (GitOps; runs git-seed first)
#   make argo-ui               # port-forward the Argo CD UI (+ prints the password)
#   make scenario N=01         # print a scenario card
#   make check N=01            # verify you actually completed a scenario
#   make serve-answers N=02    # serve ONLY that card's answer (omit N for the whole key)
#   make down                  # destroy everything (DO THIS when done!)

ENV ?= dev
N   ?= 01

# ---- Cross-OS bits ----
ifeq ($(OS),Windows_NT)
  PYTHON        := python
  SERVE_ANSWERS := powershell -NoProfile -ExecutionPolicy Bypass -File scripts/serve-answers.ps1
  DETECTED_OS   := Windows
else
  PYTHON        := python3
  SERVE_ANSWERS := bash scripts/serve-answers.sh
  DETECTED_OS   := $(shell uname -s)
endif

BOOT := $(PYTHON) scripts/bootstrap.py

# Pulled from scripts/config.toml (no hardcoding here). Override on the CLI if needed.
AWS_PROFILE ?= $(shell $(BOOT) $(ENV) --print aws_profile 2>/dev/null)
AWS_REGION  ?= $(shell $(BOOT) $(ENV) --print aws_region 2>/dev/null)
export AWS_PROFILE
export AWS_REGION

# Repo-local kubeconfig (git-ignored): this playground NEVER touches ~/.kube/config.
# Exported so every kubectl in every target below - and the scripts they call -
# automatically uses it. For your own shell: eval "$(make kubeconfig-env)".
KUBECONFIG_FILE := $(CURDIR)/.kubeconfig-daily-eks-practice
export KUBECONFIG := $(KUBECONFIG_FILE)

.DEFAULT_GOAL := help
.PHONY: help config init plan apply up down output kubeconfig kubeconfig-env git-seed app-deploy \
        app-status argo-repo argo-sync argo-ui argo-password drill-allow drill-image grafana-ui scenario check serve-answers \
        answers-gen fmt clean guard-env

help: ## Show this help
	@echo "Daily EKS Practice ($(DETECTED_OS)) - ENV=$(ENV), profile=$(AWS_PROFILE), region=$(AWS_REGION)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Config: scripts/config.toml (copy from scripts/config.example.toml)."
	@echo "Cost reminder: the control plane bills ~\$$0.10/hr while it exists - 'make down' when finished."

guard-env:
	@case "$(ENV)" in dev) : ;; *) echo "ENV must be dev (got '$(ENV)')"; exit 1;; esac

config: guard-env ## Regenerate the env's tfvars from scripts/config.toml
	$(BOOT) $(ENV) --generate-only

init: guard-env ## Generate tfvars, then terraform init (S3 backend)
	$(BOOT) $(ENV) init -input=false

plan: init ## terraform plan
	$(BOOT) $(ENV) plan

apply: init ## terraform apply (creates AWS resources - COSTS MONEY)
	$(BOOT) $(ENV) apply

up: init ## terraform apply, auto-approved (creates AWS resources - COSTS MONEY)
	$(BOOT) $(ENV) apply -auto-approve

down: guard-env ## terraform destroy, auto-approved (RUN THIS WHEN DONE to stop charges)
	@$(PYTHON) scripts/pre-destroy.py
	$(BOOT) $(ENV) init -input=false
	$(BOOT) $(ENV) destroy -auto-approve

output: guard-env ## Show terraform outputs
	$(BOOT) $(ENV) output

kubeconfig: guard-env ## Write a REPO-LOCAL kubeconfig (.kubeconfig-daily-eks-practice) - never touches ~/.kube/config
	@aws eks update-kubeconfig --name $$($(BOOT) $(ENV) output -raw cluster_name) \
	  --region $(AWS_REGION) --profile $(AWS_PROFILE) --kubeconfig $(KUBECONFIG_FILE)
	@echo ""
	@echo "Wrote $(KUBECONFIG_FILE) (your ~/.kube/config is untouched)."
	@echo "make targets use it automatically. For your own kubectl in this shell:"
	@echo "  linux/wsl:   eval \"\$$(make kubeconfig-env)\""
	@echo "  powershell:  \$$env:KUBECONFIG = \"$(KUBECONFIG_FILE)\""

kubeconfig-env: ## Print the export line for your shell (eval "$$(make kubeconfig-env)")
	@echo "export KUBECONFIG=$(KUBECONFIG_FILE)"

argo-repo: ## Give Argo CD read access to this private repo (token from your gh CLI login)
	$(PYTHON) scripts/argo-repo.py

git-seed: ## Publish this repo into the in-cluster git server (Argo CD's only source)
	$(PYTHON) scripts/git-seed.py

app-deploy: git-seed ## Register the practice app with Argo CD (reads from cluster git)
	$(PYTHON) scripts/gen-argocd-app.py
	kubectl apply -f argocd/generated/practice-app.yaml
	@echo ""
	@echo "Argo CD now owns the app, reading from cluster git. Run 'make argo-sync'."

argo-sync: ## Manually Sync the practice app in Argo CD, then wait until it is Healthy
	@kubectl -n argocd patch application practice-app --type merge \
	  -p '{"operation":{"initiatedBy":{"username":"make argo-sync"},"sync":{"syncStrategy":{"hook":{}}}}}'
	@echo "Sync triggered - waiting for practice-app to become Healthy (up to 180s)..."
	@kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/practice-app --timeout=180s
	@kubectl -n practice-app get deploy

app-status: ## Quick look at the practice app
	kubectl -n practice-app get deploy,pod,svc,ingress,pvc

argo-password: ## Print the Argo CD initial admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo ""

argo-ui: ## Port-forward the Argo CD UI to https://localhost:8080 (user: admin)
	@echo "Argo CD -> http://localhost:8080  (user: admin, password below)"
	@$(MAKE) --no-print-directory argo-password
	kubectl -n argocd port-forward svc/argocd-server 8080:80

drill-allow: ## Re-point the drill ALB security group at your CURRENT public IP
	@$(PYTHON) scripts/drill-allow.py

drill-image: ## Build and push the drill GUI image to your own registry
	@$(PYTHON) scripts/drill-image.py

grafana-ui: ## Port-forward Grafana to http://localhost:3000 (user: admin)
	@echo "Grafana -> http://localhost:3000  (user: admin, password: make output -> grafana_admin_password)"
	kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

scenario: ## Print a scenario card (checks its prereqs first), e.g. make scenario N=03
	@ls scenarios/$(N)-*.md >/dev/null 2>&1 || { echo "no scenario $(N) (see scenarios/)"; exit 1; }
	@$(PYTHON) scripts/scenario-prereqs.py $(N)
	@cat scenarios/$(N)-*.md

check: ## Verify a scenario's end state, e.g. make check N=03
	bash scenario_testing/check.sh $(N)

serve-answers: ## Serve the sealed answer key locally; scope to one card with N=NN (e.g. make serve-answers N=02)
	$(SERVE_ANSWERS) $(if $(filter command line,$(origin N)),$(N),)

answers-gen: ## Regenerate PRACTICE_ANSWERS.html from scenarios/answers/*.toml
	$(PYTHON) scripts/gen-answers.py

fmt: ## terraform fmt -recursive
	terraform -chdir=terraform fmt -recursive

clean: ## Remove local terraform caches, generated tfvars, and test artifacts
	find terraform -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
	find terraform -type d -name "test" -prune -exec rm -rf {} + 2>/dev/null || true
	find terraform -name "config.auto.tfvars.json" -delete 2>/dev/null || true
	rm -rf argocd/generated
	@echo "cleaned .terraform/, test/, generated tfvars, and argocd/generated/"
