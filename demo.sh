#!/usr/bin/env bash

TEMP_DIR="upgrade-example"
JAVA_8="8.0.442-librca"
JAVA_11="11.0.26-librca"
JAVA_17="17.0.14-librca"
JAVA_23="23.0.2-librca"
JAR_NAME="spring-petclinic-2.7.3-spring-boot.jar"

declare -A matrix

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
    #clear
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
    sdk install java $JAVA_23
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
    java -jar ./target/$JAR_NAME &
}

java_stop() {
    displayMessage "Stop the Spring Boot application"
    local npid=$(pgrep java)
    kill -9 $npid
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
    local java_version=$1
    local spring_version=$2
    local app_type=$3

    while ! http :8080/actuator/health 2>/dev/null; do sleep 1; done
    local startup_time=$(http :8080/actuator/metrics/application.started.time | jq .measurements[0].value)
    local memory_used=$(http :8080/actuator/metrics/jvm.memory.used | jq .measurements[0].value)

    # Store in matrix
    matrix["$java_version,$spring_version,$app_type,started"]="$startup_time"
    matrix["$java_version,$spring_version,$app_type,memory"]="$memory_used"

    # Show the validation table each time
    show_validation_table
}

show_validation_table() {
    displayMessage "Application Validation Metrics"

    # Print table header
    printf "%-15s %-15s %-15s %-20s %-20s\n" "Java Version" "Spring Version" "App Type" "Startup Time (ms)" "Memory Used (bytes)"
    printf "%-15s %-15s %-15s %-20s %-20s\n" "------------" "-------------" "--------" "----------------" "------------------"

    # Print table rows
    for key in "${!matrix[@]}"; do
        IFS=',' read -r java_version spring_version app_type metric <<< "$key"

        if [[ "$metric" == "started" ]]; then
            startup_time="${matrix[$key]}"
            memory_key="$java_version,$spring_version,$app_type,memory"
            memory_used="${matrix[$memory_key]}"

            printf "%-15s %-15s %-15s %-20s %-20s\n" "$java_version" "$spring_version" "$app_type" "$startup_time" "$memory_used"
        fi
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
    validate_app $JAVA_8 "2.7.3" "standard"
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
    validate_app $JAVA_11 "2.7.3" "standard"
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
    validate_app $JAVA_17 "2.7.3" "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.0.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app $JAVA_17 "3.0.x" "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.1.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app $JAVA_17 "3.1.x" "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.2.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app $JAVA_17 "3.2.x" "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.3.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app $JAVA_17 "3.3.x" "standard"
    talking_point
    java_stop
    talking_point
    #Upgrade to Spring Boot 3.4.x
    rewrite_application
    talking_point
    java_dash_jar
    talking_point
    validate_app $JAVA_17 "3.4.x" "standard"
    talking_point
    java_stop
    talking_point
    #



    # Show final summary table
    displayMessage "Final Validation Summary"
    show_validation_table
}

main