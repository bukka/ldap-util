#!/bin/bash
set -e

# OpenLDAP Version Manager Script
# Usage: ./start_ldap.sh <ldap_version> [ssl_version] [action]
# Example: ./start_ldap.sh openldap-2.6 30 start

if [ $# -lt 2 ]; then
    echo "Usage: $0 <ldap_version> <action> [ssl_version]"
    echo "  ldap_version: e.g., openldap-2.6, openldap-2.5"
    echo "  action:       start|stop|restart|status|clean|test"
    echo "  ssl_version:  SSL version (default: 30)"
    echo ""
    echo "Examples:"
    echo "  $0 openldap-2.6 start     # Start with SSL30 (foreground)"
    echo "  $0 openldap-2.5 start 31  # Start with SSL31"  
    echo "  $0 openldap-2.6 stop      # Stop specific version"
    echo "  $0 openldap-2.6 clean     # Clean and restart"
    echo "  $0 openldap-2.6 test      # Test PHP compatibility"
    echo ""
    echo "Local directories used:"
    echo "  Data: ./data/<instance>/"
    echo "  Config: ./etc/<instance>/"
    echo "  Runtime: ./run/<instance>/"
    exit 1
fi

LDAP_VERSION="$1"
ACTION="$2"
SSL_VERSION="${3:-30}"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration - use local directories
LDAP_PREFIX="/usr/local/ldap/$LDAP_VERSION-ssl$SSL_VERSION"
INSTANCE_NAME="$LDAP_VERSION-ssl$SSL_VERSION"

DATA_DIR="$SCRIPT_DIR/data/$INSTANCE_NAME"
CONFIG_DIR="$SCRIPT_DIR/etc/$INSTANCE_NAME"
SSL_DIR="$CONFIG_DIR/ssl"
RUN_DIR="$SCRIPT_DIR/run/$INSTANCE_NAME"

# Use PHP test default ports
LDAP_PORT=389
LDAPS_PORT=636

# If default ports are in use, add offset for different versions
if [ "$LDAP_VERSION" != "$(ls /usr/local/ldap/ | head -1)" ] && netstat -ln 2>/dev/null | grep -q ":$LDAP_PORT "; then
    case "$LDAP_VERSION" in
        *2.5*) PORT_OFFSET=0 ;;
        *2.6*) PORT_OFFSET=10 ;;
        *2.7*) PORT_OFFSET=20 ;;
        *) PORT_OFFSET=30 ;;
    esac
    LDAP_PORT=$((3389 + PORT_OFFSET))
    LDAPS_PORT=$((6363 + PORT_OFFSET))
    echo "Note: Using alternate ports $LDAP_PORT/$LDAPS_PORT (default ports busy)"
fi
LDAPI_SOCKET="$RUN_DIR/ldapi"
# Properly encode LDAPI path for URL
LDAPI_URL="ldapi://$(echo "$LDAPI_SOCKET" | sed 's|/|%2F|g')"

# Check if LDAP installation exists
if [ ! -x "$LDAP_PREFIX/libexec/slapd" ]; then
    echo "Error: LDAP installation not found at $LDAP_PREFIX"
    echo "Please build and install OpenLDAP first."
    exit 1
fi

# Set library path
export LD_LIBRARY_PATH="$LDAP_PREFIX/lib64:/usr/local/ssl$SSL_VERSION/lib64:$LD_LIBRARY_PATH"

# Function to get PID of running slapd
get_slapd_pid() {
    pgrep -f "slapd.*ldap://localhost:$LDAP_PORT" 2>/dev/null || echo ""
}

# Function to check if slapd is running
is_running() {
    local pid=$(get_slapd_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Function to stop slapd
stop_slapd() {
    echo "Stopping $INSTANCE_NAME..."
    local pid=$(get_slapd_pid)
    if [ -n "$pid" ]; then
        kill "$pid"
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing slapd..."
            kill -9 "$pid"
        fi
        echo "$INSTANCE_NAME stopped."
    else
        echo "$INSTANCE_NAME is not running."
    fi
}

# Function to clean all data and config
clean_instance() {
    echo "Cleaning $INSTANCE_NAME..."
    stop_slapd
    rm -rf "$DATA_DIR" "$CONFIG_DIR" "$RUN_DIR"
    echo "$INSTANCE_NAME cleaned."
}

# Function to generate TLS certificate
generate_cert() {
    echo "Generating TLS certificate for $INSTANCE_NAME..."
    
    # Helper function for certificate alt names
    alt_names() {
        (
            (
                (hostname && hostname -a && hostname -A && hostname -f) |
                xargs -n 1 |
                sort -u |
                sed -e 's/\(\S\+\)/DNS:\1/g'
            ) && (
                (hostname -i && hostname -I && echo "127.0.0.1 ::1") |
                xargs -n 1 |
                sort -u |
                sed -e 's/\(\S\+\)/IP:\1/g'
            )
        ) | paste -d, -s
    }

    /usr/local/ssl$SSL_VERSION/bin/openssl req -newkey rsa:4096 -x509 -nodes -days 3650 \
        -out "$SSL_DIR/server.crt" -keyout "$SSL_DIR/server.key" \
        -subj "/C=US/ST=Test/L=Localhost/O=$INSTANCE_NAME/CN=localhost" \
        -addext "subjectAltName = $(alt_names)"

    chmod 644 "$SSL_DIR/server.crt"
    chmod 600 "$SSL_DIR/server.key"
}

# Function to create directories
create_directories() {
    echo "Creating directories for $INSTANCE_NAME..."
    mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$SSL_DIR" "$RUN_DIR"
}

# Function to initialize configuration
init_config() {
    echo "Initializing configuration for $INSTANCE_NAME..."
    
    # Create bootstrap slapd.conf
    cat > "$CONFIG_DIR/slapd-bootstrap.conf" << EOF
# Bootstrap configuration for $INSTANCE_NAME
include $LDAP_PREFIX/etc/openldap/schema/core.schema

# Load required modules
modulepath $LDAP_PREFIX/libexec/openldap
moduleload back_mdb
moduleload back_config

pidfile $RUN_DIR/slapd.pid
argsfile $RUN_DIR/slapd.args

loglevel -1

# Config database
database config
rootdn "cn=config"
rootpw secret

# Main database
database mdb
suffix "dc=my-domain,dc=com"
rootdn "cn=Manager,dc=my-domain,dc=com"
rootpw secret
directory $DATA_DIR
maxsize 1073741824

index objectClass eq
EOF

    # Create client configuration
    cat > "$CONFIG_DIR/ldap.conf" << EOF
TLS_CACERT $SSL_DIR/server.crt
TLS_REQCERT never
EOF

    # Create connection helper script
    cat > "$CONFIG_DIR/ldap_env.sh" << EOF
#!/bin/bash
# Environment setup for $INSTANCE_NAME
export LD_LIBRARY_PATH="$LDAP_PREFIX/lib64:/usr/local/ssl$SSL_VERSION/lib64:\$LD_LIBRARY_PATH"
export LDAPCONF="$CONFIG_DIR/ldap.conf"
export LDAP_INSTANCE="$INSTANCE_NAME"
export LDAP_PREFIX="$LDAP_PREFIX"

# PHP test environment variables
export LDAP_TEST_HOST="localhost"
export LDAP_TEST_PORT="$LDAP_PORT"
export LDAP_TEST_URI="ldap://localhost:$LDAP_PORT"
export LDAP_TEST_BASE="dc=my-domain,dc=com"
export LDAP_TEST_USER="cn=Manager,dc=my-domain,dc=com"
export LDAP_TEST_PASSWD="secret"
export LDAP_TEST_SASL_USER="userA"
export LDAP_TEST_SASL_PASSWD="oops"
export LDAP_TEST_OPT_PROTOCOL_VERSION="3"

# Connection shortcuts
alias ldapsearch-local='$LDAP_PREFIX/bin/ldapsearch -H ldap://localhost:$LDAP_PORT'
alias ldapsearch-tls='$LDAP_PREFIX/bin/ldapsearch -H ldaps://localhost:$LDAPS_PORT'
alias ldapadd-local='$LDAP_PREFIX/bin/ldapadd -H ldap://localhost:$LDAP_PORT'
alias ldapmodify-local='$LDAP_PREFIX/bin/ldapmodify -H ldap://localhost:$LDAP_PORT'

echo "LDAP Environment loaded for $INSTANCE_NAME"
echo "  LDAP URL:  ldap://localhost:$LDAP_PORT"
echo "  LDAPS URL: ldaps://localhost:$LDAPS_PORT"
echo "  LDAPI:     $LDAPI_URL"
echo "  Admin DN:  cn=Manager,dc=my-domain,dc=com"
echo "  Password:  secret"
echo ""
echo "PHP Test Environment Variables Set:"
echo "  LDAP_TEST_URI=ldap://localhost:$LDAP_PORT"
echo "  LDAP_TEST_BASE=dc=my-domain,dc=com"
echo "  LDAP_TEST_USER=cn=Manager,dc=my-domain,dc=com"
echo "  LDAP_TEST_PASSWD=secret"
EOF
    chmod +x "$CONFIG_DIR/ldap_env.sh"
}

# Function to add PHP test data
add_php_test_data() {
    echo "Adding PHP test data..."
    
    # Add test entries that PHP tests expect
    $LDAP_PREFIX/bin/ldapadd -H "$LDAPI_URL" -D cn=Manager,dc=my-domain,dc=com -w secret << EOF || true
dn: o=test,dc=my-domain,dc=com
objectClass: top
objectClass: organization
o: test

dn: cn=userA,dc=my-domain,dc=com
objectclass: person
cn: userA
sn: testSN1
userPassword: oops
telephoneNumber: xx-xx-xx-xx-xx
description: user A

dn: cn=userB,dc=my-domain,dc=com
objectclass: person
cn: userB
sn: testSN2
userPassword: oopsIDitItAgain
description: user B

dn: cn=userC,cn=userB,dc=my-domain,dc=com
objectclass: person
cn: userC
sn: testSN3
userPassword: 0r1g1na1 passw0rd

dn: o=test2,dc=my-domain,dc=com
objectClass: top
objectClass: organization
o: test2
l: here
l: there
l: Antarctica
EOF
}
# Function to bootstrap cn=config
bootstrap_config() {
    echo "Bootstrapping cn=config for $INSTANCE_NAME..."
    
    # Start temporary slapd for configuration
    echo "Starting bootstrap slapd..."
    echo "Command: $LDAP_PREFIX/libexec/slapd -f $CONFIG_DIR/slapd-bootstrap.conf -h ldap://localhost:$LDAP_PORT ldaps://localhost:$LDAPS_PORT $LDAPI_URL"
    
    $LDAP_PREFIX/libexec/slapd -f "$CONFIG_DIR/slapd-bootstrap.conf" \
        -h "ldap://localhost:$LDAP_PORT ldaps://localhost:$LDAPS_PORT $LDAPI_URL" \
        -d 256 &
    local bootstrap_pid=$!
    
    echo "Bootstrap PID: $bootstrap_pid"
    sleep 5
    
    if ! kill -0 $bootstrap_pid 2>/dev/null; then
        echo "Error: Bootstrap slapd failed to start"
        echo "Checking bootstrap config file:"
        cat "$CONFIG_DIR/slapd-bootstrap.conf"
        echo ""
        echo "Checking if ports are available:"
        netstat -ln | grep -E ":$LDAP_PORT |:$LDAPS_PORT " || echo "Ports appear to be free"
        echo ""
        echo "Checking slapd binary:"
        ls -la "$LDAP_PREFIX/libexec/slapd"
        echo ""
        echo "Library path: $LD_LIBRARY_PATH"
        ldd "$LDAP_PREFIX/libexec/slapd" | head -10
        return 1
    fi
    
    echo "Bootstrap slapd started successfully"
    
    # Test basic connectivity
    echo "Testing bootstrap connectivity..."
    local test_count=0
    while [ $test_count -lt 10 ]; do
        if $LDAP_PREFIX/bin/ldapsearch -H "ldap://localhost:$LDAP_PORT" -x -s base -b "" >/dev/null 2>&1; then
            echo "Bootstrap connectivity OK"
            break
        fi
        echo "Waiting for bootstrap slapd to be ready... ($test_count/10)"
        sleep 2
        test_count=$((test_count + 1))
    done
    
    if [ $test_count -eq 10 ]; then
        echo "Warning: Bootstrap slapd not responding to queries"
    fi
    
    # Configure via LDAPI
    echo "Configuring TLS and modules..."
    
    # Configure TLS and modules
    echo "Configuring TLS and modules..."
    $LDAP_PREFIX/bin/ldapmodify -Q -Y EXTERNAL -H "$LDAPI_URL" << EOF || true
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: $SSL_DIR/server.crt
-
add: olcTLSCertificateFile
olcTLSCertificateFile: $SSL_DIR/server.crt
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $SSL_DIR/server.key
-
add: olcTLSVerifyClient
olcTLSVerifyClient: never
-
add: olcAuthzRegexp
olcAuthzRegexp: uid=usera,cn=digest-md5,cn=auth cn=usera,dc=my-domain,dc=com
-
replace: olcLogLevel
olcLogLevel: -1
EOF

    # Load modules if they exist
    echo "Loading modules..."
    $LDAP_PREFIX/bin/ldapmodify -Q -Y EXTERNAL -H "$LDAPI_URL" << EOF || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: sssvlv
-
add: olcModuleLoad
olcModuleLoad: ppolicy
-
add: olcModuleLoad
olcModuleLoad: dds
EOF

    # Add overlays
    echo "Adding overlays..."
    DBDN=$($LDAP_PREFIX/bin/ldapsearch -Q -LLL -Y EXTERNAL -H "$LDAPI_URL" -b cn=config '(&(olcRootDN=*)(olcSuffix=*))' dn 2>/dev/null | grep -i '^dn:' | sed -e 's/^dn:\s*//' || echo "olcDatabase={1}mdb,cn=config")
    
    $LDAP_PREFIX/bin/ldapadd -Q -Y EXTERNAL -H "$LDAPI_URL" << EOF || true
dn: olcOverlay=sssvlv,$DBDN
objectClass: olcOverlayConfig
objectClass: olcSssVlvConfig
olcOverlay: sssvlv
olcSssVlvMax: 10
olcSssVlvMaxKeys: 5

dn: olcOverlay=ppolicy,$DBDN
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy

dn: olcOverlay=dds,$DBDN
objectClass: olcOverlayConfig
objectClass: olcDdsConfig
olcOverlay: dds
EOF

    # Configure database index
    echo "Configuring database index..."
    $LDAP_PREFIX/bin/ldapmodify -Q -Y EXTERNAL -H "$LDAPI_URL" << EOF || true
dn: $DBDN
changetype: modify
add: olcDbIndex
olcDbIndex: entryExpireTimestamp eq
EOF

    # Add base entry - exactly as in PHP CI script
    $LDAP_PREFIX/bin/ldapadd -H "$LDAPI_URL" -D cn=Manager,dc=my-domain,dc=com -w secret << EOF || true
dn: dc=my-domain,dc=com
objectClass: top
objectClass: organization
objectClass: dcObject
dc: my-domain
o: php ldap tests
EOF

    # Add PHP test data
    add_php_test_data

    # Stop bootstrap slapd
    echo "Stopping bootstrap slapd..."
    kill $bootstrap_pid
    wait $bootstrap_pid 2>/dev/null || true
}

# Function to start slapd
start_slapd() {
    if is_running; then
        echo "$INSTANCE_NAME is already running on ports $LDAP_PORT/$LDAPS_PORT"
        return 0
    fi
    
    echo "Starting $INSTANCE_NAME in foreground..."
    echo "  LDAP:  ldap://localhost:$LDAP_PORT"
    echo "  LDAPS: ldaps://localhost:$LDAPS_PORT"
    echo "  LDAPI: ldapi://$LDAPI_SOCKET"
    echo ""
    echo "Press Ctrl+C to stop"
    echo ""
    
    # Check if we need to initialize
    if [ ! -d "$CONFIG_DIR/slapd.d" ] || [ ! -f "$SSL_DIR/server.crt" ]; then
        echo "Initializing $INSTANCE_NAME..."
        create_directories
        generate_cert
        init_config
        bootstrap_config
        echo ""
    fi
    
    # Start slapd in foreground with debug output
    exec $LDAP_PREFIX/libexec/slapd \
        -F "$CONFIG_DIR/slapd.d" \
        -h "ldap://localhost:$LDAP_PORT ldaps://localhost:$LDAPS_PORT $LDAPI_URL" \
        -d 256
}

# Function to show status
show_status() {
    echo "Status for $INSTANCE_NAME:"
    echo "  Script directory: $SCRIPT_DIR"
    echo "  Installation: $LDAP_PREFIX"
    echo "  Data directory: $DATA_DIR"
    echo "  Config directory: $CONFIG_DIR"
    echo "  LDAP port: $LDAP_PORT"
    echo "  LDAPS port: $LDAPS_PORT"
    echo "  LDAPI socket: $LDAPI_SOCKET"
    echo "  LDAPI URL: $LDAPI_URL"
    
    if is_running; then
        local pid=$(get_slapd_pid)
        echo "  Status: RUNNING (PID: $pid)"
    else
        echo "  Status: STOPPED"
    fi
    
    if [ -f "$CONFIG_DIR/ldap_env.sh" ]; then
        echo "  Environment: $CONFIG_DIR/ldap_env.sh"
    fi
}

# Main action handler
case "$ACTION" in
    start)
        start_slapd
        ;;
    stop)
        stop_slapd
        ;;
    restart)
        stop_slapd
        sleep 2
        start_slapd
        ;;
    status)
        show_status
        ;;
    clean)
        clean_instance
        echo "Run '$0 $LDAP_VERSION start $SSL_VERSION' to reinitialize."
        ;;
    test)
        if ! is_running; then
            echo "Error: $INSTANCE_NAME is not running. Start it first."
            exit 1
        fi
        
        echo "Testing PHP compatibility for $INSTANCE_NAME..."
        source "$CONFIG_DIR/ldap_env.sh" >/dev/null 2>&1
        
        echo "1. Testing LDAP connection (port $LDAP_PORT):"
        $LDAP_PREFIX/bin/ldapsearch -H "ldap://localhost:$LDAP_PORT" -D "cn=Manager,dc=my-domain,dc=com" -w secret -b "dc=my-domain,dc=com" "(objectClass=*)" dn
        
        echo ""
        echo "2. Testing LDAPS connection (port $LDAPS_PORT):"
        $LDAP_PREFIX/bin/ldapsearch -H "ldaps://localhost:$LDAPS_PORT" -D "cn=Manager,dc=my-domain,dc=com" -w secret -b "dc=my-domain,dc=com" "(objectClass=*)" dn
        
        echo ""
        echo "3. Testing PHP test data:"
        $LDAP_PREFIX/bin/ldapsearch -H "ldap://localhost:$LDAP_PORT" -D "cn=Manager,dc=my-domain,dc=com" -w secret -b "dc=my-domain,dc=com" "(cn=userA)" cn sn
        
        echo ""
        echo "Environment variables for PHP tests:"
        echo "  LDAP_TEST_URI=$LDAP_TEST_URI"
        echo "  LDAP_TEST_BASE=$LDAP_TEST_BASE"
        echo "  LDAP_TEST_USER=$LDAP_TEST_USER"
        echo "  LDAP_TEST_PASSWD=$LDAP_TEST_PASSWD"
        ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Valid actions: start, stop, restart, status, clean, test"
        exit 1
        ;;
esac
