#!/bin/bash -e

printf '\e[0;33m %-15s \e[0m Starting...\n' [ServiceManagerTests]

function log() {
  text="$2"
  if [[ $1 == "OK" ]]; then
    printf '\e[0;33m %-15s \e[32m SUCCESS:\e[0m %s \n' [ServiceManagerTests] "$text"
  else
    printf '\e[0;33m %-15s \e[0;31m FAILED:\e[0m %s \n' [ServiceManagerTests] "$text"
  fi
}

# 1. submit sla-template before submitting a service
SLA_TEMPLATE_ID=$(curl -XPOST "https://localhost/api/sla-template" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN' -d '{
    "name": "compss-hello-world",
    "state": "started",
    "details":{
        "type": "template",
        "name": "compss-hello-world",
        "provider": { "id": "mf2c", "name": "mF2C Platform" },
        "client": { "id": "c02", "name": "A client" },
        "creation": "2018-01-16T17:09:45.01Z",
        "guarantees": [
            {
                "name": "TestGuarantee",
                "constraint": "execution_time < 1000"
            }
        ]
    }
}' | jq -res 'if . == [] then null else .[] | .["resource-id"] end') &&
  log "OK" "sla-template $SLA_TEMPLATE_ID created successfully" [SLAManager] ||
  log "NO" "failed to create new sla-template $SLA_TEMPLATE_ID" [SLAManager]

# 2. submit hello-world service
SERVICE_ID=$(curl -XPOST "https://localhost/api/service" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN' -d '{
    "name": "compss-hello-world",
    "description": "hello world example",
    "exec": "mf2c/compss-test:it2",
    "exec_type": "compss",
    "sla_templates": ["'"$SLA_TEMPLATE_ID"'"],
    "agent_type": "normal",
    "num_agents": 1,
    "cpu_arch": "x86-64",
    "os": "linux",
    "storage_min": 0,
    "req_resource": ["sensor_1"],
    "opt_resource": ["sensor_2"]
}' | jq -es 'if . == [] then null else .[] | .["resource-id"] end') &&
  log "OK" "service $SERVICE_ID created successfully" ||
  log "NO" "failed to create new service $SERVICE_ID"

# 3. check if service is categorized
SERVICE_ID=$(echo $SERVICE_ID | tr -d '"')
CATEGORY=$(curl -XGET "https://localhost/api/${SERVICE_ID}" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN' |
  jq -es 'if . == [] then null else .[] | .["category"] end') &&
  log "OK" "service $SERVICE_ID was categorized as $CATEGORY" ||
  log "NO" "service $SERVICE_ID is not categorized"

# 4. submit service-instance before checking QoS
SERVICE_INSTANCE=$(curl -XPOST "http://localhost:46000/api/v2/lm/service" -ksS -H 'content-type: application/json' -d '{
    "service_id": "'$SERVICE_ID'"
}' | jq -es 'if . == [] then null else .[] | .service_instance end') &&
  log "OK" "service-instance $(jq -r '.id' <<<"${SERVICE_INSTANCE}") launched successfully" ||
  log "NO" "failed to launch service-instance $(jq -r '.id' <<<"${SERVICE_INSTANCE}")"

# 5. check QoS (provider) from service-instance
SERVICE_INSTANCE_ID=$(jq -r '.id' <<<"${SERVICE_INSTANCE}")
(curl -XGET "https://localhost/sm/api/${SERVICE_INSTANCE_ID}" -ksS |
  jq -es 'if . == [] then null else .[] | select(.status == 200) end') >/dev/null 2>&1 &&
  log "OK" "QoS provider checked service-instance $SERVICE_INSTANCE_ID successfully" ||
  log "NO" "QoS provider failed to check service-instance $SERVICE_INSTANCE_ID"

# 6. check if sla-agreement is created
SI_STATUS="created-not-initialized"
while [ "$SI_STATUS" = "created-not-initialized" ]; do
  sleep 5
  SERVICE_INSTANCE=$(curl "https://localhost/api/$SERVICE_INSTANCE_ID" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN')
  SI_STATUS=$(echo "$SERVICE_INSTANCE" | jq -re ".status")
  log "INFO" "service instance status = $SI_STATUS..." [LifecycleManager]
done
AGREEMENT_ID=$(echo "$SERVICE_INSTANCE" | jq -re ".agreement")
if [[ -n "$AGREEMENT_ID" && "$AGREEMENT_ID" =~ ^agreement/.*$ ]]; then
  log "OK" "agreement created successfully" [SlaManagement]
else
  log "NO" "failed to create agreement" [SlaManagement]
fi

# 7. check if qos-model (provider) is added
QOS_MODEL_ID=$(curl -XGET 'https://localhost/api/qos-model?$filter=service/href="'$SERVICE_ID'"&$filter=agreement/href="'$AGREEMENT_ID'"' \
  -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN' |
  jq -es 'if . == [] then null else .[] | .["qos-models"][0].id end') &&
  log "OK" "qos-model $QOS_MODEL_ID for agreement $AGREEMENT_ID was created successfully" ||
  log "NO" "qos-model for agreement $AGREEMENT_ID does not exist"

# 8. start an operation during 60 seconds
LM_OUTPUT=$(curl -XPUT "https://localhost/sm/api/service-instances/${SERVICE_INSTANCE_ID}/der" -ksS -H 'content-type: application/json' -d '{
    "operation":"start-job",
    "ceiClass":"es.bsc.compss.agent.test.TestItf",
    "className":"es.bsc.compss.agent.test.Test",
    "hasResult":false,
    "methodName":"main",
    "parameters":"<params paramId=\"0\"><direction>IN</direction><stream>UNSPECIFIED</stream><type>OBJECT_T</type><array paramId=\"0\"><componentClassname>java.lang.String</componentClassname><values><element paramId=\"0\"><className>java.lang.String</className><value xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" xsi:type=\"xs:string\">60</value></element></values></array></params>"
}')
if [[ ! $(echo "${LM_OUTPUT}" | jq -r ".error" 2>/dev/null) == "false" ]]; then
  log "NO" "failed to launch compss operation"
else
  log "OK" "operation started successfully"
fi

# 9. check if there are new service-operations-reports
REPORT_EXIST="false"
while [ "$REPORT_EXIST" = "false" ]; do
  sleep 1
  SERVICE_OPERATION_REPORTS=$(curl "https://localhost/api/service-operation-report" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN')
  (echo "$SERVICE_OPERATION_REPORTS" | jq -es 'if . == [] then null else .[] end') &&
    log "OK" "service-operation-reports are created successfully" ||
    log "NO" "no service-operation-report created"
  REPORT_EXIST="true"
done

# 10. check if new agents are added to the service-instance by QoS enforcement
AGENTS_ADDED="false"
while [ "$AGENTS_ADDED" = "false" ]; do
  sleep 1
  SERVICE_INSTANCE=$(curl "https://localhost/api/$SERVICE_INSTANCE_ID" -ksS -H 'content-type: application/json' -H 'slipstream-authn-info: super ADMIN')
  NUM_AGENTS=$(echo "$SERVICE_INSTANCE" | jq -es '.agents | length')
  if ((NUM_AGENTS > 1)); then
    log "OK" "agents added to service-instance successfully"
    AGENTS_ADDED="true"
  else
    log "NO" "agents are not added yet"
  fi
done
