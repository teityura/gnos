.PHONY: default deploy setup tfvars init plan apply backup clean

TF := terraform -chdir=terraform

default: deploy
deploy: init apply
setup: tfvars init

tfvars:
	test -f terraform/secrets.auto.tfvars || \
	  cp terraform/secrets.auto.tfvars.sample terraform/secrets.auto.tfvars

init:
	$(TF) init

plan: init
	$(TF) plan

apply: init
	$(TF) apply -auto-approve

backup:
	./backup.sh

clean:
	$(TF) destroy -auto-approve
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl
	rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup
