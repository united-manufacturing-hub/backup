#!/bin/bash

NAMESPACES="united-manufacturing-hub mgmtcompanion"
REPLICA_FILE="replica_counts.txt"

# Check if the replica file exists
if [ ! -f $REPLICA_FILE ]; then
    echo "Replica count file does not exist. Exiting..."
    exit 1
fi

# Read the replica file and restore the counts
for NAMESPACE in $NAMESPACES; do
    while IFS= read -r line; do
        # Read type, name, and replica count from the line
        read TYPE NAME REPLICA <<<$(echo $line)
        echo "Restoring $TYPE $NAME to $REPLICA replicas."
        # Restore the replica count
        $(which kubectl) scale $TYPE $NAME --replicas=$REPLICA -n $NAMESPACE --kubeconfig /etc/rancher/k3s/k3s.yaml
    done <"$REPLICA_FILE"
done
