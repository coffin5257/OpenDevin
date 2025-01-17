#!/bin/bash
set -eo pipefail

##############################################################
##           CONSTANTS AND ENVIRONMENTAL VARIABLES          ##
##############################################################

TMP_FILE="${TMP_FILE:-tmp.log}"

if [ -z $WORKSPACE_MOUNT_PATH ]; then
  WORKSPACE_MOUNT_PATH=$(pwd)
fi
if [ -z $WORKSPACE_BASE ]; then
  WORKSPACE_BASE=$(pwd)
fi

WORKSPACE_MOUNT_PATH+="/_test_workspace"
WORKSPACE_BASE+="/_test_workspace"
WORKSPACE_MOUNT_PATH_IN_SANDBOX="/workspace"

echo "WORKSPACE_BASE: $WORKSPACE_BASE"
echo "WORKSPACE_MOUNT_PATH: $WORKSPACE_MOUNT_PATH"
echo "WORKSPACE_MOUNT_PATH_IN_SANDBOX: $WORKSPACE_MOUNT_PATH_IN_SANDBOX"

mkdir -p $WORKSPACE_BASE

# use environmental variable if exists, otherwise use "ssh"
SANDBOX_BOX_TYPE="${SANDBOX_TYPE:-ssh}"
# TODO: we should also test PERSIST_SANDBOX = true, once it's fixed
PERSIST_SANDBOX=false
MAX_ITERATIONS=15

agents=(
  "DelegatorAgent"
  "ManagerAgent"
  "BrowsingAgent"
  "MonologueAgent"
  "CodeActAgent"
  "PlannerAgent"
  "CodeActSWEAgent"
)
tasks=(
  "Fix typos in bad.txt."
  "Write a shell script 'hello.sh' that prints 'hello'."
  "Use Jupyter IPython to write a text file containing 'hello world' to '/workspace/test.txt'."
  "Write a git commit message for the current staging area."
  "Install and import pymsgbox==1.0.9 and print it's version in /workspace/test.txt."
  "Browse localhost:8000, and tell me the ultimate answer to life."
)
test_names=(
  "test_edits"
  "test_write_simple_script"
  "test_ipython"
  "test_simple_task_rejection"
  "test_ipython_module"
  "test_browse_internet"
)

num_of_tests=${#test_names[@]}
num_of_agents=${#agents[@]}

##############################################################
##                      FUNCTIONS                           ##
##############################################################

# run integration test against a specific agent & test
run_test() {
  local pytest_cmd="poetry run pytest -s ./tests/integration/test_agent.py::$test_name"

  # Check if TEST_IN_CI is defined
  if [ -n "$TEST_IN_CI" ]; then
    pytest_cmd+=" --cov=agenthub --cov=opendevin --cov-report=xml --cov-append"
  fi

  SANDBOX_BOX_TYPE=$SANDBOX_BOX_TYPE \
    PERSIST_SANDBOX=$PERSIST_SANDBOX \
    WORKSPACE_BASE=$WORKSPACE_BASE \
    WORKSPACE_MOUNT_PATH=$WORKSPACE_MOUNT_PATH \
    WORKSPACE_MOUNT_PATH_IN_SANDBOX=$WORKSPACE_MOUNT_PATH_IN_SANDBOX \
    MAX_ITERATIONS=$MAX_ITERATIONS \
    AGENT=$agent \
    $pytest_cmd 2>&1 | tee $TMP_FILE

  # Capture the exit code of pytest
  pytest_exit_code=${PIPESTATUS[0]}

  if grep -q "docker.errors.DockerException" $TMP_FILE; then
    echo "Error: docker.errors.DockerException found in the output. Exiting."
    echo "Please check if your Docker daemon is running!"
    exit 1
  fi

  if grep -q "tenacity.RetryError" $TMP_FILE; then
    echo "Error: tenacity.RetryError found in the output. Exiting."
    echo "This is mostly a transient error. Please retry."
    exit 1
  fi

  if grep -q "ExceptionPxssh" $TMP_FILE; then
    echo "Error: ExceptionPxssh found in the output. Exiting."
    echo "Could not connect to sandbox via ssh. Please stop any stale docker container and retry."
    exit 1
  fi

  if grep -q "Address already in use" $TMP_FILE; then
    echo "Error: Address already in use found in the output. Exiting."
    echo "Browsing tests need a local http server. Please check if there's any zombie process running start_http_server.py."
    exit 1
  fi

  # Return the exit code of pytest
  return $pytest_exit_code
}

# browsing capability needs a local http server
launch_http_server() {
  poetry run python tests/integration/start_http_server.py &
  HTTP_SERVER_PID=$!
  echo "Test http server launched, PID = $HTTP_SERVER_PID"
  sleep 10
}

cleanup() {
  echo "Cleaning up before exit..."
  if [ -n "$HTTP_SERVER_PID" ]; then
    echo "Killing HTTP server..."
    kill $HTTP_SERVER_PID
    unset HTTP_SERVER_PID
  fi
  [ -f $TMP_FILE ] && rm $TMP_FILE
  echo "Cleanup done!"
}

# Trap the EXIT signal to run the cleanup function
trap cleanup EXIT

# generate prompts again, using existing LLM responses under tests/integration/mock/[agent]/[test_name]/response_*.log
# this is a compromise; the prompts might be non-sense yet still pass the test, because we don't use a real LLM to
# respond to the prompts. The benefit is developers don't have to regenerate real responses from LLM, if they only
# apply a small change to prompts.
regenerate_without_llm() {
  # set -x to print the command being executed
  set -x
  SANDBOX_BOX_TYPE=$SANDBOX_BOX_TYPE \
    PERSIST_SANDBOX=$PERSIST_SANDBOX \
    WORKSPACE_BASE=$WORKSPACE_BASE \
    WORKSPACE_MOUNT_PATH=$WORKSPACE_MOUNT_PATH \
    WORKSPACE_MOUNT_PATH_IN_SANDBOX=$WORKSPACE_MOUNT_PATH_IN_SANDBOX \
    MAX_ITERATIONS=$MAX_ITERATIONS \
    FORCE_APPLY_PROMPTS=true \
    AGENT=$agent \
    poetry run pytest -s ./tests/integration/test_agent.py::$test_name
  set +x
}

regenerate_with_llm() {
  if [[ "$test_name" = "test_browse_internet" ]]; then
    launch_http_server
  fi

  rm -rf $WORKSPACE_BASE/*
  if [ -d "tests/integration/workspace/$test_name" ]; then
    cp -r tests/integration/workspace/$test_name/* $WORKSPACE_BASE
  fi

  rm -rf logs
  rm -rf tests/integration/mock/$agent/$test_name/*
  # set -x to print the command being executed
  set -x
  echo -e "/exit\n" | \
    DEBUG=true \
    SANDBOX_BOX_TYPE=$SANDBOX_BOX_TYPE \
    PERSIST_SANDBOX=$PERSIST_SANDBOX \
    WORKSPACE_BASE=$WORKSPACE_BASE \
    WORKSPACE_MOUNT_PATH=$WORKSPACE_MOUNT_PATH AGENT=$agent \
    WORKSPACE_MOUNT_PATH_IN_SANDBOX=$WORKSPACE_MOUNT_PATH_IN_SANDBOX \
    poetry run python ./opendevin/core/main.py \
    -i $MAX_ITERATIONS \
    -t "$task Do not ask me for confirmation at any point." \
    -c $agent
  set +x

  mkdir -p tests/integration/mock/$agent/$test_name/
  mv logs/llm/**/* tests/integration/mock/$agent/$test_name/

}

##############################################################
##                      MAIN PROGRAM                        ##
##############################################################


if [ "$num_of_tests" -ne "${#test_names[@]}" ]; then
  echo "Every task must correspond to one test case"
  exit 1
fi

rm -rf logs
rm -rf $WORKSPACE_BASE/*
for ((i = 0; i < num_of_tests; i++)); do
  task=${tasks[i]}
  test_name=${test_names[i]}

  # skip other tests if only one test is specified
  if [[ -n "$ONLY_TEST_NAME" && "$ONLY_TEST_NAME" != "$test_name" ]]; then
    continue
  fi

  for ((j = 0; j < num_of_agents; j++)); do
    agent=${agents[j]}

    # skip other agents if only one agent is specified
    if [[ -n "$ONLY_TEST_AGENT" && "$ONLY_TEST_AGENT" != "$agent" ]]; then
      continue
    fi

    echo -e "\n\n\n\n========STEP 1: Running $test_name for $agent========\n\n\n\n"
    rm -rf $WORKSPACE_BASE/*
    if [ -d "tests/integration/workspace/$test_name" ]; then
      cp -r "tests/integration/workspace/$test_name"/* $WORKSPACE_BASE
    fi

    if [ "$TEST_ONLY" = true ]; then
      set -e
    else
      # Temporarily disable 'exit on error'
      set +e
    fi

    TEST_STATUS=1
    if [ -z $SKIP_TEST ]; then
      run_test
      TEST_STATUS=$?
    fi
    # Re-enable 'exit on error'
    set -e

    if [[ $TEST_STATUS -ne 0 ]]; then

      if [ "$FORCE_USE_LLM" = true ]; then
        echo -e "\n\n\n\n========FORCE_USE_LLM, skipping step 2 & 3========\n\n\n\n"
      elif [ ! -d "tests/integration/mock/$agent/$test_name" ]; then
        echo -e "\n\n\n\n========No existing mock responses for $agent/$test_name, skipping step 2 & 3========\n\n\n\n"
      else
        echo -e "\n\n\n\n========STEP 2: $test_name failed, regenerating prompts for $agent WITHOUT money cost========\n\n\n\n"

        # Temporarily disable 'exit on error'
        set +e
        regenerate_without_llm

        echo -e "\n\n\n\n========STEP 3: $test_name prompts regenerated for $agent, rerun test again to verify========\n\n\n\n"
        run_test
        TEST_STATUS=$?
        # Re-enable 'exit on error'
        set -e
      fi

      if [[ $TEST_STATUS -ne 0 ]]; then
        echo -e "\n\n\n\n========STEP 4: $test_name failed, regenerating prompts and responses for $agent WITH money cost========\n\n\n\n"

        regenerate_with_llm

        echo -e "\n\n\n\n========STEP 5: $test_name prompts and responses regenerated for $agent, rerun test again to verify========\n\n\n\n"
        # Temporarily disable 'exit on error'
        set +e
        run_test
        TEST_STATUS=$?
        # Re-enable 'exit on error'
        set -e

        if [[ $TEST_STATUS -ne 0 ]]; then
          echo -e "\n\n\n\n========$test_name for $agent RERUN FAILED========\n\n\n\n"
          echo -e "There are multiple possibilities:"
          echo -e "  1. The agent is unable to finish the task within $MAX_ITERATIONS steps."
          echo -e "  2. The agent thinks itself has finished the task, but fails the validation in the test code."
          echo -e "  3. There is something non-deterministic in the prompt."
          echo -e "  4. There is a bug in this script, or in OpenDevin code."
          echo -e "NOTE: Some of the above problems could sometimes be fixed by a retry (with a more powerful LLM)."
          echo -e "      You could also consider improving the agent, increasing MAX_ITERATIONS, or skipping this test for this agent."
          exit 1
        else
          echo -e "\n\n\n\n========$test_name for $agent RERUN PASSED========\n\n\n\n"
          sleep 1
        fi
      else
          echo -e "\n\n\n\n========$test_name for $agent RERUN PASSED========\n\n\n\n"
          sleep 1
      fi
    else
      echo -e "\n\n\n\n========$test_name for $agent PASSED========\n\n\n\n"
      sleep 1
    fi
  done
done

rm -rf logs
rm -rf $WORKSPACE_BASE
echo "Done!"
