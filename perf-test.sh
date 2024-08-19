#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex



# based on https://github.com/openstack-k8s-operators/install_yamls/blob/main/devsetup/scripts/edpm-deploy-instance.sh

# IMG vars
IMG=cirros-0.5.2-x86_64-disk.img
URL=http://download.cirros-cloud.net/0.5.2/$IMG
DISK_FORMAT=qcow2
RAW=$IMG

# ARG vars
SHOW_USAGE=false
INIT=false
CYCLES=0
RESULT_FILE=results.csv

TIMEFORMAT=%R

OS_CMD=openstack

parse_args() {
	while [[ -n "${1+xxx}" ]]; do
		case $1 in
		-h | --help)
			SHOW_USAGE=true
			break
			;;
		--init)
			INIT=true
			shift
			;;
		--cycles)
			shift
			CYCLES="$1"
			shift
			;;
		--result_file)
			shift
			RESULT_FILE=$1
			shift
			;;
		--use_os_profiler)
			shift
			OS_CMD="$OS_CMD --os-profile SECRET_KEY"
			shift
			;;
		*)
			echo Unknown argument: \"$1\"
			return 1
			;;
		esac
	done
	return 0
}

print_usage() {
	local scr
	scr="$(basename "$0")"

	read -r -d '' help <<-EOF_HELP || true
		Usage:
		  $scr
		  $scr  --init
		  $scr  --cycles 5 --result_file results.csv
		  $scr  -h|--help


		Options:
		  -h|--help            show this help
		  --init               download the image and run a single cycle to ensure the environment is the same at the start of each cycle
		  --cycles             how many cycles of the scenario to do. Each cycle will be measured and time saved to the results (default: 0)
		  --result_file        path to a file where to save the results in CSV format. (default: results.csv)
		  --use_os_profiler    execute the commands to use os-profiler
		
		Each cycle seems to take a little over 2 minutes

	EOF_HELP

	echo -e "$help"
	return 0
}

download_image() {
	# Create Image
	curl -L -# $URL > /tmp/$IMG
	if type qemu-img >/dev/null 2>&1; then
	    RAW=$(echo $IMG | sed s/img/raw/g)
	    qemu-img convert -f qcow2 -O raw /tmp/$IMG /tmp/$RAW
	    DISK_FORMAT=raw
	fi
}

perf_test_scenario() {
	set -ex
	####################
	# Create resources #
	####################
	$OS_CMD image show cirros || \
	    $OS_CMD image create --container-format bare --disk-format $DISK_FORMAT cirros < /tmp/$RAW

	# Create flavor
	$OS_CMD flavor show m1.small || \
	    $OS_CMD flavor create --ram 512 --vcpus 1 --disk 1 --ephemeral 1 m1.small

	# Create networks
	$OS_CMD network show private || $OS_CMD network create private --share
	$OS_CMD subnet show priv_sub || $OS_CMD subnet create priv_sub --subnet-range 10.0.0.64/26 --network private --subnet-pool shared-default-subnetpool-v4
	$OS_CMD network show public || $OS_CMD network create public --external --provider-network-type flat --provider-physical-network datacentre
	$OS_CMD subnet show pub_sub || \
	    $OS_CMD subnet create pub_sub --subnet-range 192.168.110.0/24 --allocation-pool start=192.168.110.200,end=192.168.110.210 --gateway 192.168.110.1 --no-dhcp --network public
	$OS_CMD router show priv_router || {
	    $OS_CMD router create priv_router
	    $OS_CMD router add subnet priv_router priv_sub
	    $OS_CMD router set priv_router --external-gateway public
	}

	# Create security group and icmp/ssh rules
	$OS_CMD security group show basic || {
	    $OS_CMD security group create basic
	    $OS_CMD security group rule create basic --protocol icmp --ingress --icmp-type -1
	    $OS_CMD security group rule create basic --protocol tcp --ingress --dst-port 22
	}

	# List External compute resources
	$OS_CMD compute service list
	$OS_CMD network agent list

	# Create an instance
	$OS_CMD server show test || {
	    $OS_CMD server create --flavor m1.small --image cirros --nic net-id=private test --security-group basic
	    # I want to wait for the server to finish creating here. Adding --wait above doesn't work with OSProfiler.
	    # So wait by calling a few openstack * list.
	    wait_by_listing
	    wait_by_listing
	    fip=$($OS_CMD floating ip create public -f value -c id)
	    fip_ip=$($OS_CMD floating ip show $fip -f value -c floating_ip_address)
	    $OS_CMD server add floating ip test $fip_ip
	}
	$OS_CMD server list

	############################
	# Delete created resources #
	############################
	$OS_CMD floating ip delete $fip
	$OS_CMD server delete test
	$OS_CMD security group delete basic
	$OS_CMD router remove subnet priv_router priv_sub
	$OS_CMD router delete priv_router
	$OS_CMD subnet delete pub_sub
	$OS_CMD subnet delete priv_sub
	$OS_CMD image delete cirros

	wait_by_listing

}

init() {
	download_image
	perf_test_scenario
}

wait_by_listing() {
	$OS_CMD floating ip list
	$OS_CMD server list
	$OS_CMD security group list
	$OS_CMD router list
	$OS_CMD subnet list
	$OS_CMD network list
	$OS_CMD image list
}

execute_testing() {
	for i in $(seq 1 $CYCLES) ; do
		if [[ $i -eq 1 ]]; then
			rm -f $RESULT_FILE
		fi
		echo Starting a cycle $i out of $CYCLES
		#TIME=$({ time perf_test_scenario 2> /dev/null > /dev/null; } 2>&1)
		TIME=$({ time perf_test_scenario; } 2>&1)
		echo Last cycle took $TIME
		echo -n $TIME >> $RESULT_FILE
		if [[ $i -lt $CYCLES ]]; then
			echo -n , >> $RESULT_FILE
		else
			echo "" >> $RESULT_FILE
		fi
	done
}

main() {
	parse_args "$@" || { echo "Failed to parse args" && exit 1; }
	$SHOW_USAGE && {
		print_usage
		exit 0
	}
	$INIT && {
		init
		exit 0
	}
	execute_testing
}

main "$@"
