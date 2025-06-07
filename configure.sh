ossl_version=${1:-30}
ldap_version="$(basename $(pwd))"

# Set environment
echo export CPPFLAGS="-I/usr/local/ssl$ossl_version/include -DLDAP_DEBUG -DDEBUG"
echo export LDFLAGS="-L/usr/local/ssl$ossl_version/lib64 -Wl,-rpath,/usr/local/ssl$ossl_version/lib64"
echo export CFLAGS="-g -O0 -Wall -Wextra -fno-omit-frame-pointer"
echo export LD_LIBRARY_PATH="/usr/local/ssl$ossl_version/lib64"

# Configure
echo ./configure \
    --with-tls=openssl \
    --enable-debug=yes \
    --enable-syslog \
    --enable-slapd \
    --enable-modules \
    --enable-backends=mod \
    --enable-overlays=mod \
    --enable-cleartext \
    --enable-crypt \
    --disable-perl \
    --prefix=/usr/local/ldap/$ldap_version-ssl$ossl_version \
    --libdir=/usr/local/ldap/$ldap_version-ssl$ossl_version/lib64
