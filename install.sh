#!/bin/bash
set -e

_usage() {
    echo "Usage: install.sh playbook_xx_lamp.yml [-p|--provision] [-v|--verbose] [-s|--security-privileged] [-n|--hosts]"
    echo
    echo "This will create an lxc container with the variables defined in the playbook"
    exit 1
}


_parse_yaml() {
    local prefix=$2
    local s
    local w
    local fs
    s='[[:space:]]*'
    w='[a-zA-Z0-9_]*'
    fs="$(echo @|tr @ '\034')"
    sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
    awk -F"$fs" '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=(\"%s\")\n", "'"$prefix"'",vn, $2, $3);
        }
    }' | sed 's/_=/+=/g'
}


_is_online() {
    IP="|"
    while [ "$IP" == "|" ]; do
        sleep 1
        IP=$(lxc list "$_vars_lxcname" | grep "$_vars_lxcname" | awk '{ print $6 }')
    done
}


_success() {
    echo -ne '\r[\033[0;32m'
    echo -n " OK "
    echo -e "\033[0m] $LAST_MESSAGE"
}


_error() {
    echo -e '\033[0;31m'
    echo "Error: $*"
    echo -e '\033[0m'
    exit 1
}


_echo() {
    LAST_MESSAGE="$*"
    echo -n "[    ] $LAST_MESSAGE"
}


### MAIN
UP="\033[2A"                           # move cursor up
OPTS=$(getopt --options vphsn \
              --longoptions verbose,provision,help,security-privileged,hosts \
              --name "install.sh" \
              -- "$@" )

eval set -- "$OPTS"

VERBOSE=0
PROVISION=0
SECURITY=0
PLAY=
OUT='/dev/null'
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v | --verbose)
            echo "Setting verbosity"
            VERBOSE=1
            OUT="$(tty)"
            shift
            ;;

        -p | --provision)
            PROVISION=1
            shift
            ;;

        -s | --security-privileged)
            SECURITY=1
            shift
            ;;
        -n | --hosts)
            HOSTS=1
            shift
            ;;
        --)
            shift
            PLAY="$1"
            shift
            ;;

        *)
            _usage
            ;;
    esac
done


[[ -f "$PLAY" ]] || _error "playbook $PLAY not found"
_UID=$(id -u)
_GID=$(id -g)
cp $PLAY /tmp/$PLAY
sed -i "s/\(.*hostuid\:\).*/\1 $_UID/g" /tmp/$PLAY
sed -i "s/\(.*hostgid\:\).*/\1 $_GID/g" /tmp/$PLAY
cp /tmp/$PLAY $PLAY

SUBUID=root:$_UID:1

# give lxd permission to map your user/group id through
grep "$SUBUID" /etc/subuid -qs || sudo usermod --add-subuids "${_UID}-${_UID}" --add-subgids "${_GID}-${_GID}" root
UID_OFFSET=$(grep 'root:.*:1000000000' /etc/subuid | head -1 | awk -F: '{ print $2 }')
GID_OFFSET=$(grep 'root:.*:1000000000' /etc/subgid | head -1 | awk -F: '{ print $2 }')

# set lxd authoritative DNS Zone
echo -e "auth-zone=lxd\ndns-loop-detect" | lxc network set lxdbr0 raw.dnsmasq -

# get playbook variables
_echo "Get playbook variables"
sed -e "s/\(.*\)#.*$/\1/g" -e "s/---//g"  -e "s/- hosts.*//g" "$PLAY" > /tmp/playbook.yml
eval $(_parse_yaml /tmp/playbook.yml) && _success || _error "$?"
((VERBOSE)) && _parse_yaml /tmp/playbook.yml


case $_vars_vmos in
    "d7")
        _lxd_image="images:debian/wheezy/amd64";;
    "d8")
        _lxd_image="images:debian/jessie/amd64";;
    "d9")
        _lxd_image="images:debian/9/amd64";;
    "c6")
        _lxd_image="images:centos/6/amd64";;
    "c7")
        _lxd_image="images:centos/7/amd64";;
    "c8")
        _lxd_image="images:centos/8/amd64";;
    "s15")
        _lxd_image="images:opensuse/15.0";;
    "u12")
        _lxd_image="ubuntu:precise";;
    "u14")
        _lxd_image="ubuntu:trusty";;
    "u16")
        _lxd_image="ubuntu:xenial";;
    "u18")
        _lxd_image="ubuntu:bionic";;
    "u20")
        _lxd_image="ubuntu:focal";;
    *)
        echo "No OS defined using 20"
        _vars_vmos="u20"
        _lxd_image="ubuntu:focal";;
esac

case $_vars_vmsw in
    "lemp") ;;
    "lamp") ;;
    *) _vars_vmsw="lemp" ;;
esac

if [ -z "$_vars_ip" ]; then
    _vars_ip=10.20.30.$(expr $((16#`echo $_vars_lxcname | md5sum | cut -c 1-4`)) % 255)
fi

if [ -z "$_vars_lxcname" ]; then
    _vars_lxcname="ubu$_vars_vmos-$_vars_vmsw"
fi

if [ -z "${_vars_mount[0]}" ]; then
    _vars_mount[0]="./"
fi
_vars_mount[0]=$(echo ${_vars_mount[0]} | tr -d " ")

if [ -z "${_vars_mount[1]}" ]; then
    _vars_mount[1]="/tmp/lxd"
fi
_vars_mount[1]=$(echo ${_vars_mount[1]} | tr -d " ")


# create lxd image if needed
_echo "Creating lxd image: $_vars_lxcname ... "
if lxc list | grep " $_vars_lxcname " &>/dev/null; then
    echo -n "already exists. Continuing"
    _success
else
    lxc init "$_lxd_image" "$_vars_lxcname" || _error "$?"
    echo -e "$UP"
    _success
fi


# set config privileged
if ((SECURITY)); then
    _echo "Setting security.nesting "
    lxc config set "$_vars_lxcname" security.nesting true && _success || _error "$?"
    _echo "Setting security.privileged "
    lxc config set "$_vars_lxcname" security.privileged true && _success || _error "$?"
fi

# create mounts
_echo "Create mounts: ${_vars_mount[0]}"
if [ ! -d "${_vars_mount[0]}" ]; then
    echo -n "creating ${_vars_mount[0]}"
    mkdir -p "${_vars_mount[0]}" || _error "$?"
fi
_success
_vars_mount[0]="$(realpath ${_vars_mount[0]})/"
_echo "Adding mounts to container."
lxc config device add "$_vars_lxcname" share disk source="${_vars_mount[0]}" path="${_vars_mount[1]}" &>/dev/null && _success || \
    (if [ $? -eq 1 ]; then echo " Already mounted"; echo -e "$UP"; _success else _error $?; fi)


_echo "Setting uid/gid www-data"
lxc config set $_vars_lxcname raw.idmap "both $_UID 33" && _success


_echo "Attache lxdbr0 network"
lxc network attach lxdbr0 "$_vars_lxcname" eth0 eth0 && _success || _success
# lxc network attach lxdbr0 "$_vars_lxcname" eth0 $(ip route get 8.8.8.8 | head -n1 | cut -d' ' -f5) && _success


_echo "Set ip address to $_vars_ip"
lxc config device set $_vars_lxcname eth0 ipv4.address $_vars_ip && _success


# start lxc
if ! lxc list "$_vars_lxcname" | grep "RUNNING" &>/dev/null; then
    _echo "Start $_vars_lxcname"
    lxc start "$_vars_lxcname" || _error "$?"
    _is_online
    _success
fi


if ((HOSTS)); then
    _echo "add $_vars_lxcname to /etc/hosts"
    MARKER1='# BEGIN LXC'
    MARKER2='# END LXC'
    if ! grep -qz "$MARKER1.*$MARKER2" /etc/hosts; then
        echo -e "\n$MARKER1\n$MARKER2" | sudo tee -a /etc/hosts
    fi
    sudo sed -i -e "/$MARKER1/,/$MARKER2/{/$_vars_ip.*/d" -e "s/$MARKER2/$_vars_ip $_vars_lxcname\n$MARKER2/}" /etc/hosts && _success || _error
fi

if ((PROVISION)); then
    _echo "set ssh key"
    _pub_key="$(cat ~/.ssh/id_rsa.pub)"
    lxc exec "$_vars_lxcname" -- sh -c "mkdir -p /root/.ssh && echo $_pub_key >> /root/.ssh/authorized_keys" && _success || _error "$?"


    _echo "install python"
    # if ((VERBOSE)); then echo; fi
    case "$_vars_vmos" in
        c*)
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "yum install -y python36 && update-alternatives --set python /usr/bin/python3" >$OUT && _success ;;#|| _error "$?";;
        s*)
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "zypper install -y python3 && update-alternatives --install /usr/bin/python python /usr/bin/python3 1" >$OUT && _success || _error "$?";;
        u*)
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "apt-get update && apt-get install -y python" >$OUT && _success || _error "$?";;
        d*)
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "apt-get update && apt-get install -y python" >$OUT && _success || _error "$?";;
    esac


    _echo "install extra dependencies"
    case $_vars_vmos in
        "u12"|"u14"|"u16"|"u18"|"u20")
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "apt-get install -y --reinstall openssh-server" >$OUT || _error "$?"
            ;;
        "d7"|"d8"|"d9")
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "apt-get install -y --reinstall openssh-server" >$OUT || _error "$?"
            ;;
        "c6")
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "yum install -y openssh-server && service sshd start" >$OUT || _error "$?"
            ;;
        "c7"|"c8")
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "yum install -y openssh-server && systemctl start sshd" >$OUT || _error "$?"
            ;;
        "s15")
            ((VERBOSE)) && echo
            lxc exec "$_vars_lxcname" -- sh -c "zypper install -y openssh && systemctl enable --now sshd" >$OUT || _error "$?"
            ;;
    esac
    _success



    _lxc_ip=$(lxc list "$_vars_lxcname" | grep "$_vars_lxcname" | awk '{ print $6 }')
    _echo "start playbook: ansible-playbook -i \"$_lxc_ip,\" $PLAY"; echo
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_lxc_ip"
    export ANSIBLE_HOST_KEY_CHECKING=False
    ansible-playbook -i "$_lxc_ip," "$PLAY"
fi



lxc exec "$_vars_lxcname" -- bash -c "cat /etc/issue; echo ; echo \"IP : \$(hostname -I)\"; echo"
echo "mount source=${_vars_mount[0]} path=${_vars_mount[1]}"
