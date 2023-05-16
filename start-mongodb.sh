#!/bin/sh

# Map input values from the GitHub Actions workflow to shell variables
MONGODB_VERSION=$1
MONGODB_REPLICA_SET=$2
MONGODB_PORT=$3
MONGODB_DB=$4
MONGODB_USERNAME=$5
MONGODB_PASSWORD=$6
CONTAINER_NAME=$7
echo "::group::Container name [$CONTAINER_NAME]"

if [ -z "$MONGODB_PORT" ]; then
  echo "::group::Finding available port"
  # scan all used ports in the machine outside docker, then find the available one
  start_port=27000
  end_port=28000
  for port in $(seq $start_port $end_port); do
    (echo >/dev/tcp/localhost/$port) >/dev/null 2>&1 && continue || { MONGODB_PORT=$port; break; };
  done
  echo "::group::Selected port [$MONGODB_PORT]"
fi

if [ -z "$MONGODB_VERSION" ]; then
  echo ""
  echo "Missing MongoDB version in the [mongodb-version] input. Received value: $MONGODB_VERSION"
  echo ""

  exit 2
fi


echo "::group::Selecting correct MongoDB client"
if [ "`echo $MONGODB_VERSION | cut -c 1`" = "4" ]; then
  MONGO_CLIENT="mongo"
else
  MONGO_CLIENT="mongosh --quiet"
fi
echo "  - Using [$MONGO_CLIENT]"
echo ""
echo "::endgroup::"


if [ -z "$MONGODB_REPLICA_SET" ]; then
  echo "::group::Starting single-node instance, no replica set"
  echo "  - port [$MONGODB_PORT]"
  echo "  - version [$MONGODB_VERSION]"
  echo "  - database [$MONGODB_DB]"
  echo "  - credentials [$MONGODB_USERNAME:$MONGODB_PASSWORD]"
  echo ""

  docker run --name $CONTAINER_NAME --publish $MONGODB_PORT:27017 -e MONGO_INITDB_DATABASE=$MONGODB_DB -e MONGO_INITDB_ROOT_USERNAME=$MONGODB_USERNAME -e MONGO_INITDB_ROOT_PASSWORD=$MONGODB_PASSWORD --detach mongo:$MONGODB_VERSION

  if [ $? -ne 0 ]; then
      echo "Error starting MongoDB Docker container"
      exit 2
  fi
  echo "::endgroup::"

  return
fi


echo "::group::Starting MongoDB as single-node replica set"
echo "  - port [$MONGODB_PORT]"
echo "  - version [$MONGODB_VERSION]"
echo "  - replica set [$MONGODB_REPLICA_SET]"
echo ""

docker run --name $CONTAINER_NAME --publish $MONGODB_PORT:$MONGODB_PORT --detach mongo:$MONGODB_VERSION --replSet $MONGODB_REPLICA_SET --port $MONGODB_PORT

if [ $? -ne 0 ]; then
    echo "Error starting MongoDB Docker container"
    exit 2
fi
echo "::endgroup::"


echo "::group::Waiting for MongoDB to accept connections"
sleep 1
TIMER=0

until docker exec --tty $CONTAINER_NAME $MONGO_CLIENT --port $MONGODB_PORT --eval "db.serverStatus()" # &> /dev/null
do
  sleep 1
  echo "."
  TIMER=$((TIMER + 1))

  if [[ $TIMER -eq 20 ]]; then
    echo "MongoDB did not initialize within 20 seconds. Exiting."
    exit 2
  fi
done
echo "::endgroup::"


echo "::group::Initiating replica set [$MONGODB_REPLICA_SET]"

docker exec --tty $CONTAINER_NAME $MONGO_CLIENT --port $MONGODB_PORT --eval "
  rs.initiate({
    \"_id\": \"$MONGODB_REPLICA_SET\",
    \"members\": [ {
       \"_id\": 0,
      \"host\": \"localhost:$MONGODB_PORT\"
    } ]
  })
"

echo "Success! Initiated replica set [$MONGODB_REPLICA_SET]"
echo "::endgroup::"


echo "::group::Checking replica set status [$MONGODB_REPLICA_SET]"
docker exec --tty $CONTAINER_NAME $MONGO_CLIENT --port $MONGODB_PORT --eval "
  rs.status()
"
echo "::endgroup::"
