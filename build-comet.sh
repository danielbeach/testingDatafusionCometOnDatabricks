#!/usr/bin/env bash
set -euxo pipefail

echo "=== Setting up Java environment ==="

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export JDK_HOME="$JAVA_HOME"
export PATH="$JAVA_HOME/bin:/root/.cargo/bin:$PATH"

export C_INCLUDE_PATH="$JAVA_HOME/include:$JAVA_HOME/include/linux:${C_INCLUDE_PATH:-}"
export CPATH="$JAVA_HOME/include:$JAVA_HOME/include/linux:${CPATH:-}"

JVM_LIB="$(find "$JAVA_HOME" -name libjvm.so | head -n 1)"

if [ -z "$JVM_LIB" ]; then
    echo "ERROR: Could not find libjvm.so"
    find /usr/lib/jvm -name libjvm.so
    exit 1
fi

JVM_DIR="$(dirname "$JVM_LIB")"

export LD_LIBRARY_PATH="$JVM_DIR:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$JVM_DIR:${LIBRARY_PATH:-}"
export RUSTFLAGS="-L native=$JVM_DIR -l dylib=jvm"

echo "JAVA_HOME=$JAVA_HOME"
echo "JDK_HOME=$JDK_HOME"
echo "JVM_LIB=$JVM_LIB"
echo "JVM_DIR=$JVM_DIR"

java -version
javac -version

echo "=== Verifying Java installation ==="

ls -lah "$JAVA_HOME/include/jni.h"
ls -lah "$JAVA_HOME/include/linux/jni_md.h"
ls -lah "$JVM_LIB"

echo "=== Setting up source code ==="

cd /workspace

if [ ! -d datafusion-comet ]; then
    git clone https://github.com/apache/datafusion-comet.git
fi

cd datafusion-comet

git fetch --all --tags

echo "=== Available tags ==="
git tag | tail -20

#
# Uncomment if you want a specific release
#
# git checkout 0.16.0

echo "=== Cleaning previous builds ==="

cd native
cargo clean
cd ..

rm -rf spark/target || true

echo "=== Building Comet ==="

PROFILES="-Pspark-4.0 -Pscala-2.13 -Pjdk17" make release

echo "=== Collecting JARs ==="

mkdir -p /workspace/output

find . -name "*.jar" -exec cp {} /workspace/output/ \;

echo "=== Output JARs ==="

find /workspace/output -name "*.jar" -exec ls -lh {} \;

echo "=== Looking for Comet Spark JAR ==="

find /workspace/output -name "*comet-spark*spark4.0*2.13*.jar"

echo "=== Looking for Comet Common JAR ==="

find /workspace/output -name "*comet-common*spark4.0*2.13*.jar"

echo "=== Build Complete ==="
