#!/bin/bash
#
# Build and deploy ONE platform's libndbclient jar for com.mysql.ndb:libndbclient-multiarch.
#
# Usage: deploy-native.sh <version> <classifier> <lib-file> [extra mvn args...]
#   classifier: linux-x86_64 | linux-aarch64 | macos-aarch64
#   lib-file:   the libndbclient shared library built for that platform
#   extra args: passed to every mvn invocation, e.g. -DJenkinsHops.RepoID=HopsEE
#               -DJenkinsHops.User=... -DJenkinsHops.Password=... (see README)
#
# The three platforms are deployed by three independent runs on three machines (two RonDB
# Jenkins jobs plus a manual macOS run) in no particular order. Every run first makes sure
# the shared pom is on the server, uploading it only if it is missing, and then uploads its
# own classified jar. Whoever finishes first uploads the pom; everyone else finds it.
#
# Environment overrides, used for local testing against a file:// repository:
#   DEPLOY_URL      default https://nexus.hops.works/repository/hops-artifacts
#   DEPLOY_REPO_ID  default HopsEE  (the <server> id in ~/.m2/settings.xml)

set -euo pipefail

GROUP_ID=com.mysql.ndb
ARTIFACT_ID=libndbclient-multiarch
# Pinned and fully qualified so the result does not depend on the Maven version running us.
# The RonDB build image runs Maven 3.5.4 (OracleLinux 8 RPM), so every pin must require
# Maven <= 3.5.4: deploy 3.1.1 and dependency 3.6.1 need 3.2.5, help 3.2.0 needs 3.0
# (help 3.4.0 needs 3.6.3 and refuses to run).
DEPLOY_PLUGIN=org.apache.maven.plugins:maven-deploy-plugin:3.1.1
DEPENDENCY_PLUGIN=org.apache.maven.plugins:maven-dependency-plugin:3.6.1
HELP_PLUGIN=org.apache.maven.plugins:maven-help-plugin:3.2.0
DEPLOY_URL=${DEPLOY_URL:-https://nexus.hops.works/repository/hops-artifacts}
DEPLOY_REPO_ID=${DEPLOY_REPO_ID:-HopsEE}

usage() {
  echo "Usage: $0 <version> <classifier> <lib-file> [extra mvn args...]" >&2
  echo "  classifier: linux-x86_64 | linux-aarch64 | macos-aarch64" >&2
  exit 1
}

[ $# -ge 3 ] || usage
VERSION=$1
CLASSIFIER=$2
LIB_FILE=$3
shift 3

case "$CLASSIFIER" in
  linux-x86_64|linux-aarch64) LIB_EXT=so ;;
  macos-aarch64)              LIB_EXT=dylib ;;
  *) echo "Error: unknown classifier '$CLASSIFIER'" >&2; usage ;;
esac

if [ ! -f "$LIB_FILE" ]; then
  echo "Error: library file not found: $LIB_FILE" >&2
  exit 1
fi
LIB_FILE="$(cd "$(dirname "$LIB_FILE")" && pwd)/$(basename "$LIB_FILE")"

cd "$(dirname "$0")"

# The committed pom carries a version placeholder. Substitute it for this run only and put
# the original back on exit so the checkout is never left dirty.
if ! grep -q ___RONDBVERSION___ pom.xml; then
  echo "Error: pom.xml does not contain the ___RONDBVERSION___ placeholder" >&2
  exit 1
fi
cp pom.xml pom.xml.orig
trap 'mv -f pom.xml.orig pom.xml' EXIT
# -i.bak works on both GNU and BSD sed.
sed -i.bak "s/___RONDBVERSION___/$VERSION/g" pom.xml && rm -f pom.xml.bak

echo "Building $ARTIFACT_ID $VERSION $CLASSIFIER from $LIB_FILE"
rm -rf natives target
mkdir -p "natives/$CLASSIFIER"
# RonDB ships the library as e.g. libndbclient.so.6.1.0 plus a libndbclient.so symlink to
# it. Consumers load the library by its plain name, so the jar must contain a regular file
# called libndbclient.<ext> with no version in the name: dereference whatever we were given.
STAGED_LIB="natives/$CLASSIFIER/libndbclient.$LIB_EXT"
cp -L "$LIB_FILE" "$STAGED_LIB"
if [ -L "$STAGED_LIB" ] || [ ! -s "$STAGED_LIB" ]; then
  echo "Error: staged library is not a regular non-empty file: $STAGED_LIB" >&2
  exit 1
fi

mvn -B package -Dnative.classifier="$CLASSIFIER" "$@"

JAR_FILE="target/$ARTIFACT_ID-$VERSION-$CLASSIFIER.jar"
if [ ! -f "$JAR_FILE" ]; then
  echo "Error: expected jar was not built: $JAR_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# Shared pom: upload only if the server does not have it yet.
# ---------------------------------------------------------------------------------------
GROUP_PATH=${GROUP_ID//.//}
POM_URL="$DEPLOY_URL/$GROUP_PATH/$ARTIFACT_ID/$VERSION/$ARTIFACT_ID-$VERSION.pom"

# The repository does not allow anonymous reads, so the pom is fetched through Maven, which
# authenticates with the same server entry the upload uses. Maven stores the download in
# its local repository, so find out where that is.
#
# Both Maven calls below run from an empty directory: run inside the project, Maven would
# satisfy the request from the project itself (same coordinates) without asking the server.
CHECK_DIR="$PWD/target/pom-check"
mkdir -p "$CHECK_DIR"
# Maven logs errors to stdout, so on failure the command substitution would swallow them
# and set -e would kill the script with no output at all: check explicitly and echo what
# Maven said.
set +e
HELP_OUTPUT=$(cd "$CHECK_DIR" && mvn -B -q $HELP_PLUGIN:evaluate -Dexpression=settings.localRepository -DforceStdout "$@")
HELP_RC=$?
set -e
LOCAL_REPO=$(echo "$HELP_OUTPUT" | tail -1)
if [ $HELP_RC -ne 0 ] || [ ! -d "$LOCAL_REPO" ]; then
  echo "Error: could not determine Maven's local repository (exit $HELP_RC). Maven said:" >&2
  echo "$HELP_OUTPUT" >&2
  exit 1
fi
LOCAL_POM_DIR="$LOCAL_REPO/$GROUP_PATH/$ARTIFACT_ID/$VERSION"
REMOTE_POM="$LOCAL_POM_DIR/$ARTIFACT_ID-$VERSION.pom"

# 0: remote pom exists and is identical to ours, 1: absent (or not reachable), 2: differs.
remote_pom_state() {
  # Compare against the server, never against a stale cached copy.
  rm -rf "$LOCAL_POM_DIR"
  (cd "$CHECK_DIR" && mvn -B -q $DEPENDENCY_PLUGIN:get -Dartifact="$GROUP_ID:$ARTIFACT_ID:$VERSION:pom" \
    -Dtransitive=false -DremoteRepositories="$DEPLOY_REPO_ID::default::$DEPLOY_URL" \
    "$@") >/dev/null 2>&1 || return 1
  [ -f "$REMOTE_POM" ] || return 1
  cmp -s pom.xml "$REMOTE_POM" || return 2
  return 0
}

deploy_pom() {
  mvn -B $DEPLOY_PLUGIN:deploy-file -Dfile=pom.xml -DpomFile=pom.xml -Dpackaging=pom \
    -DgroupId=$GROUP_ID -DartifactId=$ARTIFACT_ID -Dversion="$VERSION" \
    -DrepositoryId="$DEPLOY_REPO_ID" -Durl="$DEPLOY_URL" "$@"
}

set +e; remote_pom_state "$@"; POM_STATE=$?; set -e
case $POM_STATE in
  0)
    echo "pom already deployed and identical, skipping: $POM_URL"
    ;;
  2)
    echo "Error: a DIFFERENT pom is already deployed at $POM_URL" >&2
    diff pom.xml "$REMOTE_POM" >&2 || true
    exit 1
    ;;
  1)
    echo "pom not deployed yet, uploading: $POM_URL"
    set +e; deploy_pom "$@"; RC=$?; set -e
    if [ $RC -ne 0 ]; then
      # Another platform's run may have uploaded the pom between our check and our upload.
      # If the repository is configured to reject redeploys that makes our upload fail;
      # accept it as success as long as the pom now on the server matches ours.
      set +e; remote_pom_state "$@"; POM_STATE=$?; set -e
      if [ $POM_STATE -eq 0 ]; then
        echo "pom upload failed but an identical pom is now on the server, continuing"
      else
        echo "Error: pom upload failed (exit $RC)" >&2
        exit $RC
      fi
    fi
    ;;
esac

# ---------------------------------------------------------------------------------------
# This platform's jar.
# ---------------------------------------------------------------------------------------
echo "Uploading $JAR_FILE"
mvn -B $DEPLOY_PLUGIN:deploy-file -Dfile="$JAR_FILE" -Dpackaging=jar \
  -Dclassifier="$CLASSIFIER" -DgeneratePom=false \
  -DgroupId=$GROUP_ID -DartifactId=$ARTIFACT_ID -Dversion="$VERSION" \
  -DrepositoryId="$DEPLOY_REPO_ID" -Durl="$DEPLOY_URL" "$@"

echo "Deployed $GROUP_ID:$ARTIFACT_ID:$VERSION:$CLASSIFIER to $DEPLOY_URL"
