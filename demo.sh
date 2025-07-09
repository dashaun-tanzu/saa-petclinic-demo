#!/usr/bin/env bash

TEMP_DIR="upgrade-example"
JAVA_8="8.0.452-librca"
JAVA_11="11.0.27-librca"
JAVA_17="17.0.15-librca"
JAVA_21="21.0.7-librca"
JAVA_24="24.0.1-librca"
JAR_NAME="spring-petclinic-2.7.3-spring-boot.jar"

declare -A matrix
# Array to track the order of entries
declare -a run_order

# Track first run metrics for percentage calculations
FIRST_STARTUP_TIME=""
FIRST_MEMORY_USED=""

# Function definitions

check_dependencies() {
    local tools=("vendir" "http")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "$tool not found. Please install $tool first."
            exit 1
        fi
    done
}

talking_point() {
    wait
    clear
}

init_sdkman() {
    local sdkman_init="${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
    if [[ -f "$sdkman_init" ]]; then
        source "$sdkman_init"
    else
        echo "SDKMAN not found. Please install SDKMAN first."
        exit 1
    fi
    sdk update
    sdk install java $JAVA_8
    sdk install java $JAVA_11
    sdk install java $JAVA_17
    sdk install java $JAVA_21
    sdk install java $JAVA_24
}

init() {
    rm -rf "$TEMP_DIR"
    mkdir "$TEMP_DIR"
    cd "$TEMP_DIR" || exit
    clear
}

use_java() {
    local version=$1
    displayMessage "Use Java $version"
    sdk use java "$version"
    java -version
}

clone_app() {
    displayMessage "Clone the Spring Pet Clinic"
    git clone https://github.com/dashaun/spring-petclinic.git ./
}

java_dash_jar() {
    displayMessage "Start the Spring Boot application (with java -jar)"
    mvnd -q clean package -DskipTests
    # Run java in the background with output redirected
    java -jar ./target/$JAR_NAME > /dev/null 2>&1 &
    # Store the PID
    APP_PID=$!
    # Let the shell "forget" about this process so it won't show "Killed" messages
    disown $APP_PID
}

java_stop() {
    displayMessage "Stop the Spring Boot application"

    # Find the Java process without showing output
    local npid=$(pgrep java 2>/dev/null)
    if [ -n "$npid" ]; then
        # Redirect all output to /dev/null to hide the "Killed" message
        { kill -9 $npid; } 2>/dev/null

        # Wait until the process is actually gone, silently
        while ps -p $npid > /dev/null 2>&1; do
            sleep 0.1
        done

        # Additional small delay to ensure resources are freed
        sleep 1
    fi

    # Ensure port 8080 is free before continuing, silently
    while netstat -tuln | grep ":8080 " > /dev/null 2>&1; do
        sleep 0.5
    done

    # Clear any leftover output that might have appeared
    echo -ne "\033[2K\r"
}

remove_extracted() {
    rm -rf application
}

aot_processing() {
  displayMessage "Package using AOT Processing"
  ./mvnw -q -Pnative clean package -DskipTests
  displayMessage "Done"
}

java_dash_jar_aot_enabled() {
  displayMessage "Start the Spring Boot application with AOT enabled"
  java -Dspring.aot.enabled=true -jar ./target/$JAR_NAME 2>&1 | tee "$1" &
}

java_dash_jar_extract() {
    displayMessage "Extract the Spring Boot application for efficiency (java -Djarmode=tools)"
    java -Djarmode=tools -jar ./target/$JAR_NAME extract --destination application
    displayMessage "Done"
}

java_dash_jar_exploded() {
    displayMessage "Start the extracted Spring Boot application, (java -jar [exploded])"
    java -jar ./application/$JAR_NAME 2>&1 | tee "$1" &
}

create_cds_archive() {
  displayMessage "Create a CDS archive"
  java -XX:ArchiveClassesAtExit=application.jsa -Dspring.context.exit=onRefresh -jar application/$JAR_NAME | grep -v "[warning][cds]"
  displayMessage "Done"
}

java_dash_jar_cds() {
  displayMessage "Start the Spring Boot application with CDS archive, Wait For It...."
  java -XX:SharedArchiveFile=application.jsa -jar application/$JAR_NAME 2>&1 | tee "$1" &
}

java_dash_jar_aot_cds() {
  displayMessage "Start the Spring Boot application with CDS archive, Wait For It...."
  java -Dspring.aot.enabled=true -XX:SharedArchiveFile=application.jsa -jar application/$JAR_NAME 2>&1 | tee "$1" &
}

validate_app() {
  displayMessage "Check application health"
  # Hit the main page to generate some load
  while ! http :8080/actuator/info 2>/dev/null; do sleep 1; done

  # Check health
  while ! http :8080/actuator/health 2>/dev/null; do sleep 1; done
}

capture_metrics() {
    local app_type=$1
    local startup_time
    local memory_used
    local boot_version

    java_version=$(http :8080/actuator/info | jq .java.version)
    startup_time=$(http :8080/actuator/metrics/application.started.time | jq .measurements[0].value)
    memory_used=$(http :8080/actuator/metrics/jvm.memory.used | jq '.measurements[0].value | floor')
    boot_version=$(http :8080/actuator/info | jq .spring.boot.version)

    # Create a unique key for this run
    local run_key="$java_version,$boot_version,$app_type"

    # Store in matrix
    matrix["$run_key,started"]="$startup_time"
    matrix["$run_key,memory"]="$memory_used"

    # Add to run order if not already present
    if ! [[ " ${run_order[*]} " =~ " ${run_key} " ]]; then
        run_order+=("$run_key")
    fi

    # Set first run metrics for percentage calculations if not already set
    if [[ -z "$FIRST_STARTUP_TIME" ]]; then
        FIRST_STARTUP_TIME="$startup_time"
        FIRST_MEMORY_USED="$memory_used"
    fi

    # Show the validation table each time
    show_validation_table
}

calculate_percentage_change() {
    local current=$1
    local baseline=$2
    local change

    if [[ "$baseline" == "0" ]]; then
        echo "N/A"
        return
    fi

    # Use scale=4 for more precision in calculation
    change=$(echo "scale=4; ($current - $baseline) / $baseline * 100" | bc)

    # Force display with 1 decimal place
    change=$(printf "%.1f" "$change")

    # Add + sign for positive changes
    if (( $(echo "$change > 0" | bc -l) )); then
        echo "+${change}%"
    else
        echo "${change}%"
    fi
}

show_validation_table() {
    displayMessage "Application Validation Metrics"

    # Print table header
    printf "%-15s %-15s %-15s %-20s %-15s %-20s %-15s\n" \
        "Java Version" "Spring Version" "App Type" "Startup Time (ms)" "Time Change" "Memory Used (bytes)" "Memory Change"
    printf "%-15s %-15s %-15s %-20s %-15s %-20s %-15s\n" \
        "------------" "-------------" "--------" "----------------" "-----------" "------------------" "-------------"

    # Print table rows in order of execution
    for run_key in "${run_order[@]}"; do
        local startup_time="${matrix["$run_key,started"]}"
        local memory_used="${matrix["$run_key,memory"]}"

        # Calculate percentage changes
        local startup_change=$(calculate_percentage_change "$startup_time" "$FIRST_STARTUP_TIME")
        local memory_change=$(calculate_percentage_change "$memory_used" "$FIRST_MEMORY_USED")

        # Parse the run_key
        IFS=',' read -r java_version spring_version app_type <<< "$run_key"

        # Note: The %-15s format will keep the percentage display with decimals intact
        printf "%-15s %-15s %-15s %-20.3f %-15s %-20.0f %-15s\n" \
            "$java_version" "$spring_version" "$app_type" \
            "$startup_time" "$startup_change" \
            "$memory_used" "$memory_change"
    done

    echo
}

rewrite_application() {
    displayMessage "Spring Application Advisor"
    advisor build-config get
    advisor upgrade-plan get
    advisor upgrade-plan apply
}

displayMessage() {
    echo "#### $1"
    echo
}

# Main execution flow

main() {
    check_dependencies
    vendir sync
    source ./vendir/demo-magic/demo-magic.sh
    export TYPE_SPEED=100
    export DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"
    export PROMPT_TIMEOUT=5

    init_sdkman
    init
    use_java $JAVA_8
    talking_point
    clone_app
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Java 11
    rewrite_application
    talking_point
    use_java $JAVA_11
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Java 17
    rewrite_application
    talking_point
    use_java $JAVA_17
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.0.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.1.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.2.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.3.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.4.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.5.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Java 21
    use_java $JAVA_21
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop
    #Upgrade to Java 24
    use_java $JAVA_24
    talking_point
    java_dash_jar
    talking_point
    validate_app
    talking_point
    capture_metrics "standard"
    talking_point
    java_stop

    # Show final summary table
    displayMessage "Final Validation Summary"
    show_validation_table
}

main