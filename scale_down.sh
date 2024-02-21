#!/bin/bash

NAMESPACES="united-manufacturing-hub mgmtcompanion"
REPLICA_FILE="replica_counts.txt"

# Ensure the replica file is empty
echo "" >$REPLICA_FILE

for NAMESPACE in $NAMESPACES; do
    # Scale down Deployments
    for DEPLOYMENT in $($(which kubectl) get deployments -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' --kubeconfig /etc/rancher/k3s/k3s.yaml); do
        # Get current replica count
        CURRENT_REPLICA=$($(which kubectl) get deployment $DEPLOYMENT -n $NAMESPACE -o jsonpath='{.spec.replicas}')
        echo "Deployment $DEPLOYMENT has $CURRENT_REPLICA replicas. Scaling down to 0."
        # Save to file
        echo "Deployment $DEPLOYMENT $CURRENT_REPLICA" >>$REPLICA_FILE
        # Scale down
        $(which kubectl) scale deployment $DEPLOYMENT --replicas=0 -n $NAMESPACE
    done

    # Scale down StatefulSets
    for STATEFULSET in $($(which kubectl) get statefulsets -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' --kubeconfig /etc/rancher/k3s/k3s.yaml); do
        # Get current replica count
        CURRENT_REPLICA=$($(which kubectl) get statefulset $STATEFULSET -n $NAMESPACE -o jsonpath='{.spec.replicas}' --kubeconfig /etc/rancher/k3s/k3s.yaml)
        echo "StatefulSet $STATEFULSET has $CURRENT_REPLICA replicas. Scaling down to 0."
        # Save to file
        echo "StatefulSet $STATEFULSET $CURRENT_REPLICA" >>$REPLICA_FILE
        # Scale down
        $(which kubectl) scale statefulset $STATEFULSET --replicas=0 -n $NAMESPACE --kubeconfig /etc/rancher/k3s/k3s.yaml
    done
done
