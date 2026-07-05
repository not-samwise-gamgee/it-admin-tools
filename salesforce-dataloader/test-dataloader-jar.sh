#!/bin/bash
# Test DataLoader JAR execution directly

CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")
JAR_PATH="$USER_HOME/Applications/Data Loader.app/Contents/Resources/dataloader-64.1.0.jar"

echo "=== Testing DataLoader JAR Execution ==="
echo "User: $CONSOLE_USER"
echo "JAR Path: $JAR_PATH"
echo

if [[ ! -f "$JAR_PATH" ]]; then
    echo "❌ JAR file not found"
    exit 1
fi

echo "=== Java Version ==="
java -version

echo
echo "=== Testing JAR with different Java options ==="

echo "1. Testing basic execution:"
cd "$USER_HOME/Applications/Data Loader.app/Contents/Resources" || exit 1
timeout 10s java -jar dataloader-64.1.0.jar --help 2>&1 | head -10

echo
echo "2. Testing with Java 8 compatibility flags:"
timeout 10s java -Djava.awt.headless=false -Xmx1024m -jar dataloader-64.1.0.jar --help 2>&1 | head -10

echo
echo "3. Testing with GUI mode:"
timeout 5s java -Djava.awt.headless=false -Dapple.awt.UIElement=false -jar dataloader-64.1.0.jar 2>&1 | head -10

echo
echo "=== Checking for Java compatibility issues ==="
java -jar dataloader-64.1.0.jar --version 2>&1 | head -5 || echo "Version check failed"

echo
echo "=== Manual launch test (will timeout after 10 seconds) ==="
timeout 10s sudo -u "$CONSOLE_USER" java -Djava.awt.headless=false -Xmx1024m -jar dataloader-64.1.0.jar 2>&1 | head -10 || echo "Launch test completed"
