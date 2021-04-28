#!/usr/bin/env bash

VAGRANT_PLUGINS="disksize vbguest sshfs openstack-provider"





VERBOSE=0
SKIP_VIRTUALBOX=0
SKIP_PLUGINS=0
VAGRANT_LATEST_RELEASE=""
VBOX_LATEST_RELEASE=""
ARCH=""
KERNEL_NAME=""
OS_NAME=""
OS_TYPE=""

mirrorsupdate=0

_compare_versions(){
	if [[ $1 == $2 ]]; then											# Versions 1 and 2 are the same
		return 0
	fi
	local IFS=.
	local i
	local ver1=($1)
	local ver2=($2)

	# fill empty fields in ver1 with zeros
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
		ver1[i]=0
	done

	for ((i=0; i<${#ver1[@]}; i++)); do
		if [[ -z ${ver2[i]} ]]; then
			# fill empty fields in ver2 with zeros
			ver2[i]=0
		fi
		if ((10#${ver1[i]} > 10#${ver2[i]})); then					# Version 1 is greater than 2
			return 1
		fi
		if ((10#${ver1[i]} < 10#${ver2[i]})); then					# Version 2 is greater than 1
			return 2
		fi
	done

	return 0
}

_has_minimum_version(){
	local result=1

	local current=$1
	local required=$2

	_compare_versions "$current" "$required"
	local ret=$?
	if [[ $ret -lt 2 ]]; then
		result=0
	fi

	return $result
}

_get_system_details(){
	local result=1

	ARCH="$(uname -m)"
	KERNEL_NAME="$(uname -s)"

	case $KERNEL_NAME in
		Linux)
			OS_NAME=$(lsb_release -is)
			if [[ "$OS_NAME" = "Debian" || "$OS_NAME" = "Ubuntu" ]]; then
				OS_TYPE="debian"
				result=0
			else
				echo "OS not supported!"
			fi
			;;
		Darwin)
			OS_NAME=$(awk '/SOFTWARE LICENSE AGREEMENT FOR macOS/' '/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf' | awk '{print $(NF-1)" "$NF}' | rev | cut -c2- | rev)
			if [[ "$ARCH" = "x86_64" ]]; then
				OS_TYPE="mac_amd64"
				result=0
			else
				echo "Architecture <$ARCH> not supported!"
			fi
			;;
		*)
			echo "OS not supported!"
	esac

	return $result
}

_apt(){
	local result=1

	if [[ "$1" = "showlatest" ]]; then
		local version=$(apt-cache policy $2 | awk '/^[ \t]+Candidate: / {print $NF}' | awk -F '-' '{print $1}')
		if [[ "$version" != "" ]]; then
			result=0
			echo "$version"
		fi
	else
		apt-get "$@" >/dev/null 2>&1
		result=$?
	fi

	return $result
}

_dmg(){
	local result=1

	case $1 in
		install)
			if [[ "echo $2 | grep '\.dmg$'" != "" && -f $2 ]]; then
				local mountpoint=$(hdiutil mount $2 2>/dev/null | tail -1 | grep '\/Volumes')
				result=$?
				local mountdevice=$(echo $mountpoint | awk '{print $1}')
				mountpoint=$(echo $mountpoint | awk -F '/Volumes' '{print $NF}')

				if [[ $result -eq 0 ]]; then
					mountpoint="/Volumes${mountpoint}"
					cp -R "$mountpoint" /Applications 2>/dev/null
					result=$?
				fi

				if [[ $result -eq 0 ]]; then
					hdiutil unmount "$mountdevice" >/dev/null 2>&1
					result=$?
				fi
			fi
			;;
	esac

	return $result
}

_install_brew(){
	curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh >/dev/null 2>&1
}

_brew(){
	local result=0

	if [[ "$(command -v brew)" = "" ]]; then
		_install_brew >/dev/null 2>&1
		result=$?
	fi
	if [[ $result -eq 0 ]]; then
		if [[ "$1" = "showlatest" ]]; then
			local url="https://formulae.brew.sh"
			local path=""
			local pkgname=$(brew search $2 | grep "${2}$")
			local basename=$(echo $pkgname | awk -F '/' '{print $(NF-1)}')
			pkgname=$(echo $pkgname | awk -F '/' '{print $NF}')
			if [[ "$pkgname" != "" ]]; then
				if [[ "$basename" != "$pkgname" ]]; then
					path+="/$basename"
				fi
				path+="/$pkgname"

				local version=$(curl --silent $url/$path | grep "version:" | awk -F '">' '{print $2}' | awk -F '</a>' '{print $1}' | cut -d, -f1)
				if [[ "$version" != "" ]]; then
					if [[ "$basename" = "cask" ]]; then
						version="cask/$version"
					fi
					echo "$version"
				else
					result=1
				fi
			fi
		else
			brew "$@"
			result=$?
		fi
	fi

	return $result
}

_mirrors_update(){
	local result=1

	if [[ $mirrorsupdate -eq 0 ]]; then
		case $OS_TYPE in
			debian)
				_apt update >/dev/null 2>&1
				result=$?
				;;
			mac_amd64)
				_brew config >/dev/null 2>&1
				result=$?
				;;
		esac
	fi

	return $result
}

_install_virtualbox(){
	local result=0

	local install=0
	if [[ "$(which virtualbox)" = "" ]]; then
		if [[ $VERBOSE -eq 1 ]]; then
			echo -n "VirtualBox not found! Installing... "
		fi
		install=1
	fi

	VBOX_LATEST_RELEASE=""
	local maccask=" "
	case $OS_TYPE in
		debian)
			VBOX_LATEST_RELEASE=$(_apt showlatest virtualbox)
			;;
		mac_amd64)
			VBOX_LATEST_RELEASE=$(_brew showlatest virtualbox)
			if [[ "$(echo $VBOX_LATEST_RELEASE | grep '^cask/')" != "" ]]; then
				maccask=" --cask "
				VBOX_LATEST_RELEASE=$(echo $VBOX_LATEST_RELEASE | cut -d/ -f2)
			fi
			;;
		*)
			echo "OS not supported!"
			result=1
			;;
	esac
	if [[ "$VBOX_LATEST_RELEASE" = "" ]]; then
		echo "Unable to find the latest release version for VirtualBox!"
		result=1
	fi

	if [[ $VERBOSE -eq 1 ]]; then
		echo "VirtualBox latest release: $VBOX_LATEST_RELEASE"
	fi

	if [[ $result -eq 0 && $install -eq 0 ]]; then
		local version=$(vboxmanage --version 2>/dev/null | awk -F '_' '{print $1}')
		if [[ $VERBOSE -eq 1 ]]; then
			echo "VirtualBox current version: $version"
		fi
		_has_minimum_version $version $VBOX_LATEST_RELEASE
		local ret=$?
		if [[ $ret -eq 0 ]]; then
			echo "VirtualBox is up to date."
		else
			if [[ $VERBOSE -eq 1 ]]; then
				echo -n "VirtualBox is not up to date! Installed: <$version>, Available: <$VBOX_LATEST_RELEASE>. Updating... "
			fi
			install=1
		fi
	fi

	if [[ $result -eq 0 && $install -eq 1 ]]; then
		_mirrors_update
	fi

	if [[ $result -eq 0 && $install -eq 1 ]]; then
		case $OS_TYPE in
			debian)
				if [[ $VERBOSE -eq 1 ]]; then
					echo "version $VBOX_LATEST_RELEASE for $OS_NAME"
				fi
				_apt install --yes virtualbox
				result=$?
				;;
			mac_amd64)
				if [[ $VERBOSE -eq 1 ]]; then
					echo "version $VBOX_LATEST_RELEASE for $OS_NAME"
				fi
				_brew install${maccask}virtualbox
				result=$?
				;;
		esac
	fi

	if [[ $result -eq 0 && "$(vboxmanage --version 2>/dev/null | awk -F '_' '{print $1}')" != "$VBOX_LATEST_RELEASE" ]]; then
		echo "Unable to install the required VirtualBox version!"
		result=1
	fi

	return $result
}

_install_vagrant(){
	local result=0

	local install=0
	local ret

	if [[ "$(which vagrant)" = "" ]]; then
		if [[ $VERBOSE -eq 1 ]]; then
			echo -n "Vagrant not found! Installing... "
		fi
		install=1
	fi

	local baseurl="https://releases.hashicorp.com/vagrant"
	local url=""
	local filename=""

	VAGRANT_LATEST_RELEASE="$(curl --silent $baseurl/ | awk -F '"' '/vagrant_/ {print $2}' | head -1 | cut -d/ -f3)"
	if [[ "$VAGRANT_LATEST_RELEASE" = "" ]]; then
		echo "Unable to find the latest release version for Vagrant!"
		result=1
	fi

	if [[ $result -eq 0 && $install -eq 0 ]]; then
		version=$(vagrant --version | awk '{print $NF}')
		_has_minimum_version $version $VAGRANT_LATEST_RELEASE
		ret=$?
		if [[ $ret -eq 0 ]]; then
			if [[ $VERBOSE -eq 1 ]]; then
				echo "Vagrant is up to date."
			fi
		else
			if [[ $VERBOSE -eq 1 ]]; then
				echo -n "Vagrant is not up to date! Installed: <$version>, Available: <$VAGRANT_LATEST_RELEASE>. Updating... "
			fi
			install=1
		fi
	fi

	if [[ $result -eq 0 && $install -eq 1 ]]; then
		url="$baseurl/$VAGRANT_LATEST_RELEASE"
		filename="vagrant_${VAGRANT_LATEST_RELEASE}_${ARCH}"
		case $OS_TYPE in
			debian)
				if [[ $VERBOSE -eq 1 ]]; then
					echo "version $VAGRANT_LATEST_RELEASE for $OS_NAME"
				fi
				curl --silent -O $url/$filename.deb
				ret=0
				if [[ -f ./$filename.deb ]]; then
					_apt install --yes ./$filename.deb
					ret=$?
					rm ./$filename.deb
				else
					ret=1
				fi
				if [[ $ret -ne 0 ]]; then
					echo "Failed to install Vagrant $VAGRANT_LATEST_RELEASE!"
					result=$ret
				fi
				;;
			mac_amd64)
				if [[ $VERBOSE -eq 1 ]]; then
					echo "version $VAGRANT_LATEST_RELEASE for $OS_NAME"
				fi
				curl --silent -O $url/$filename.dmg
				ret=0
				if [[ -f ./$filename.dmg ]]; then
					_dmg install ./$filename.dmg
					ret=$?
					rm ./$filename.dmg
				else
					ret=1
				fi
				if [[ $ret -ne 0 ]]; then
					echo "Failed to install Vagrant $VAGRANT_LATEST_RELEASE!"
					result=$ret
				fi
				;;
			*)
				echo "OS not supported!"
				result=1
				;;
		esac
	fi

	if [[ $result -eq 0 ]]; then
		_replace_vagrant_wrapper
		result=$?
	fi

	return $result
}

_replace_vagrant_wrapper(){
	local result=0

	local vagrantscript=$(which vagrant)
	if [[ "$vagrantscript" = "" ]]; then
		result=1
	fi

	if [[ $result -eq 0 && "$(head -1 $vagrantscript | grep 'bash$')" != "" && "$(wc -l $vagrantscript | cut -d' ' -f1)" -lt 10 ]]; then
		if [[ $VERBOSE -eq 1 ]]; then
			echo -n "Replacing Vagrant wrapper..."
		fi
		mv $vagrantscript $vagrantscript.bak
		result=$?

		if [[ $result -eq 0 ]]; then
			cat << EOF | tee $vagrantscript >/dev/null 2>&1
#!/bin/bash

BYPASS=0

ENVVARS="VAGRANT_OPENSTACK_VERSION_CHECK=disabled"
VAGRANT=/opt/vagrant/bin/vagrant
if [[ ! -f \$VAGRANT ]]; then
	echo "File not found: \$VAGRANT"
	exit 1
fi

if [[ "\$ENVVARS" != "" ]]; then
	for envvar in \$(echo "\$ENVVARS"); do
		export \$envvar
	done
fi




MAX_TRIES=3
SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

CURRENT_PATH=\$(pwd)

ORIG_ARGS=()
ORIG_ARGS_COUNT=\$#
while [[ \$# -gt 0 ]]; do
	ORIG_ARGS+=("\$1")
	shift
done
set -- "\${ORIG_ARGS[@]}"


ACTION=""
VMS=""
VMS_NUMBER=0
VM=""
SSH_COMMAND=""
USER=""

vagrantfile=\$CURRENT_PATH/Vagrantfile
go_ahead=0
if [[ \$BYPASS -ne 1 && -f \$vagrantfile ]]; then
	POSITIONAL=()
	SSH_POSITIONAL=()
	VMS=\$(grep -E "^[ \t]+config\.vm\.define" \$vagrantfile | awk '{print \$2}' | cut -c2- | rev | cut -c2- | rev)
	VMS_NUMBER=\$(echo "\$VMS" | wc -l)

	case \$1 in
		ssh)
			ACTION="ssh"
			for ssh_arg in \$SSH_OPTIONS; do
				SSH_POSITIONAL+=("\$ssh_arg")
			done
			go_ahead=1
			;;
		up)
			ACTION="up"
			if [[ \$VMS_NUMBER -gt 1 ]]; then
				go_ahead=1
			fi
			;;
	esac

	if [[ \$go_ahead -eq 1 ]]; then
		ssh_args=0

		previous_arg=""
		arg=""
		while [[ \$# -gt 0 ]]; do
			arg="\$1"
			save_arg=1
			case \$arg in
				ssh|up)
					save_arg=0
					;;
				-c)
					SSH_COMMAND="\$2"
					shift
					save_arg=0
					;;
				-p)
					save_arg=0
					;;
				--)															# Last normal argument was the previous one. Starting from here, there are SSH arguments
					if [[ "\$ACTION" = "ssh" ]]; then
						ssh_args=1
						if [[ "\$(echo \$previous_arg | grep '@')" != "" ]]; then
							USER=\$(echo \$previous_arg | awk -F '@' '{print \$1}')
							VM=\$(echo \$previous_arg | awk -F '@' '{print \$2}')
						else
							go_ahead=0										# Bypass to vagrant
							break
						fi
					fi
					save_arg=0
					;;
				*)
					if [[ \$ssh_args -eq 0 && \$# -eq 1 ]]; then			# Last normal argument
						case \$ACTION in
							ssh)
								if [[ "\$(echo \$arg | grep '@')" != "" ]]; then
									USER=\$(echo \$arg | awk -F '@' '{print \$1}')
									tmpVM=\$(echo \$arg | awk -F '@' '{print \$2}')
									for vm in \$VMS; do
										if [[ "\$tmpVM" = "\$vm" ]]; then
											echo "Checking <\$vm> VM status..."
											vmstatus=\$(\$VAGRANT status \$vm | grep "running")
											if [[ "\$vmstatus" != "" ]]; then
												VM=\$vm
												break
											fi
										fi
									done
									if [[ "\$VM" != "" ]]; then
										save_arg=0
									else
										go_ahead=0							# Bypass to vagrant for error message (we have a user and vm specified, but vm is not defined or not running)
										break
									fi
								else
									go_ahead=0								# Bypass to vagrant
									break
								fi
								;;
							up)												# We have to determine if the last arg was a VM (defined, running or not, we don't care) or a normal argument (then we'll have to loop over all the defined VMs)
								case \$arg in
									--provision|--no-provision|--destroy-on-error|--no-destroy-on-error|--parallel|--no-parallel|--install-provider|--no-install-provider)
										:
										;;
									--color|--no-color|--machine-readable|-v|--version|--debug|--timestamp|--debug-timestamp|--no-tty|-h|--help)
										:
										;;
									*)
										case \$previous_arg in
											--provision-with|--provider)
												:
												;;
											*)								# Well, the last arg was supposed to be a VM name, then
												VM=\$arg
												save_arg=0
												;;
										esac
								esac
								;;
						esac
					fi
					;;
			esac

			if [[ \$save_arg -eq 1 ]]; then
				if [[ \$ssh_args -eq 0 ]]; then
					if [[ "\$arg" != "" ]]; then
						POSITIONAL+=("\$arg")
					fi
				else
					if [[ "\$arg" != "" ]]; then
						SSH_POSITIONAL+=("\$arg")
					fi
				fi
			fi

			previous_arg="\$arg"
			shift
		done

		if [[ \$go_ahead -eq 1 ]]; then
			case \$ACTION in
				ssh)
					set -- "\${SSH_POSITIONAL[@]}"
					;;
				up)
					if [[ "\$VM" != "" ]]; then
						VMS="\$VM"
					fi
					set -- "\${POSITIONAL[@]}"
					;;
			esac
		fi
	fi
fi

if [[ \$go_ahead -eq 1 ]]; then
	case \$ACTION in
		ssh)
			if [[ "\$VM" != "" && "\$USER" != "" ]]; then
				echo "Searching for <\$VM> VM ssh port..."
				port=\$(\$VAGRANT ssh-config \$VM | awk '/Port / {print \$2}')
				ssh -p "\$port" "\$@" \$USER@localhost "\$SSH_COMMAND" 2>/dev/null
				ret=\$?
				if [[ \$ret -ne 0 ]]; then
					echo "Unable to establish a ssh connection with host <localhost> on port <\$port> with user <\$USER>!"
					exit \$ret
				fi
			else
				BYPASS=1
			fi
			;;
		up)
			for vm in \$VMS; do
				i=1
				while [[ \$i -le \$MAX_TRIES ]]; do
					if [[ \$i -gt 1 ]]; then
						\$VAGRANT halt \$vm
					fi
					\$VAGRANT up "\$@" \$vm
					if [[ \$? -ne 0 ]]; then
						i=\$((i + 1))
						err_msg="VAGRANT FAILED TO LAUNCH THEN CONNECT WITH SSH TO VM <\$vm>."
						if [[ \$i -le \$MAX_TRIES ]]; then
							echo "\$err_msg Retry: \$i/\$MAX_TRIES"
						else
							echo "\$err_msg No more retries for this VM!"
							read "Continue with other VMs by pressing any key, or cancel with CTRL-C"
						fi
					else
						break
					fi
				done
			done
			;;
	esac
else
	BYPASS=1
fi

if [[ \$BYPASS -eq 1 ]]; then
	set -- "\${ORIG_ARGS[@]}"
	\$VAGRANT "\$@"
fi
EOF
			result=$?
		fi
		if [[ $result -eq 0 ]]; then
			chmod +x $vagrantscript
			result=$?
		fi
		if [[ $result -eq 0 ]]; then
			echo "done"
		fi
	fi

	return $result
}

_install_vagrant_plugins_for_user(){
	local result=0

	local user=$1
	local usercheck
	local plugin
	local plugincheck
	local install=0
	local upgrade=0

	usercheck=`grep "^\$user:" /etc/passwd`
	if [[ "$usercheck" != "" && "$user" != "ubuntu" && "$user" != "vagrant" ]]; then
		echo
		echo "Checking/installing vagrant plugins for user <$user>..."
		for plugin in $VAGRANT_PLUGINS; do
			result=1

			pluginfile=$(ls "$(dirname "$(realpath "$0")")"/vagrant-$plugin-*.gem 2>/dev/null)
			plugincheck=$(su - $user -c "vagrant plugin list" | grep "^vagrant-$plugin ")
			pluginavailvers=""
			plugincurrentvers=""

			if [[ "$pluginfile" != "" ]]; then
				pluginavailvers=$(echo $pluginfile | awk -F '-' '{print $NF}' | rev | cut -c5- | rev)
			else
				pluginavailvers=$(gem list --remote vagrant-$plugin | grep "^vagrant-$plugin " | awk '{print $2}' | cut -c2- | rev | cut -c2- | rev)
			fi

			if [[ "$plugincheck" != "" ]]; then
				plugincurrentvers=$(echo $plugincheck | awk '{print $2}' | cut -d, -f1 | cut -c2-)
			fi

			install=0
			upgrade=0
			if [[ "$pluginavailvers" != "" ]]; then
				if [[ "$plugincurrentvers" != "" ]]; then
					_has_minimum_version $plugincurrentvers $pluginavailvers
					ret=$?
					if [[ $ret -ne 0 ]]; then
						echo "vagrant-$plugin: current <$plugincurrentvers>, available <$pluginavailvers>. Upgrade required..."
						install=1
						upgrade=1
					fi
				else
					echo "vagrant-$plugin: New installation required."
					install=1
				fi
			else
				echo "Error: Unable to find the plugin vagrant-$plugin"
			fi

			if [[ $install -eq 1 ]]; then
				if [[ "$pluginfile" != "" ]]; then
					pluginfile=$(realpath $pluginfile)

					su - $user -c "vagrant plugin install $pluginfile"
					result=$?
					if [[ $result -ne 0 ]]; then
						echo "Error while trying to update $pluginfile!"
						break
					fi
				else
					if [[ $upgrade -eq 1 ]]; then
						su - $user -c "vagrant plugin update vagrant-$plugin"
						result=$?
						if [[ $result -ne 0 ]]; then
							echo "Error while trying to update vagrant-$plugin!"
							break
						fi
					else
						su - $user -c "vagrant plugin install vagrant-$plugin"
						result=$?
						if [[ $result -ne 0 ]]; then
							echo "Error while trying to install vagrant-$plugin!"
							break
						fi
					fi
				fi
			else
				result=0
				if [[ $VERBOSE -eq 1 ]]; then
					echo "vagrant-$plugin has already the newest version: $plugincurrentvers"
				fi
			fi
		done

		if [[ $result -eq 0 ]]; then
			echo "done with user <$user>"
		fi
	fi

	return $result
}

_install_vagrant_plugins(){
	local result=0

	if [[ $SKIP_PLUGINS -ne 1 ]]; then
		local user
		local ret

		for user in $(ls /home); do
			result=0
			ret=1
			_install_vagrant_plugins_for_user $user
			ret=$?
			if [[ $ret -ne 0 ]]; then
				result=$ret
				break
			fi
		done

		if [[ $result -eq 0 ]]; then
			result=0
			ret=1
			_install_vagrant_plugins_for_user root
			ret=$?
			if [[ $ret -ne 0 ]]; then
				result=$ret
				break
			fi
		fi
	fi

	return $result
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
	case $1 in
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		-n|--no-virtualbox)
			SKIP_VIRTUALBOX=1
			shift
			;;
		-s|--skip-plugins)
			SKIP_PLUGINS=1
			shift
			;;
		-h|--help)
			cat << EOF
Usage: $0 [OPTION]
Automatically install/update VirtualBox, Vagrant and some Vagrant plugins with latest available versions on Debian/Ubuntu or MacOS systems.

	OPTION
	======
	-n|--no-virtualbox				Do not install VirtualBox.
	-s|--skip-plugins				Do not check/install/update Vagrant plugins (without skipping, this operation takes a while).
	-v|--verbose					Be verbose.
	-h|--help					Print this help page.
EOF
			shift
			exit 0
			;;
		*)
			POSITIONAL+=("$1")
			shift
			;;
	esac
done
set -- "${POSITIONAL[@]}"





ret=0
if [[ $(id -u) -ne 0 ]]; then
	echo "Call me with sudo!"
	exit 1
fi

_get_system_details
ret=$?
if [[ $ret -ne 0 ]]; then
	exit $ret
fi
echo "Running $OS_NAME ($KERNEL_NAME) on $ARCH"
echo
if [[ $VERBOSE -eq 0 ]]; then
	echo "Installing/Updating everything required. This may take a while..."
fi

if [[ $SKIP_VIRTUALBOX -ne 1 ]]; then
	_install_virtualbox
	ret=$?
	if [[ $ret -ne 0 ]]; then
		exit $ret
	fi
	if [[ $VERBOSE -eq 1 ]]; then
		echo
	fi
fi

_install_vagrant
ret=$?
if [[ $ret -ne 0 ]]; then
	exit $ret
fi
if [[ $VERBOSE -eq 1 ]]; then
	echo
fi

_install_vagrant_plugins
ret=$?
if [[ $ret -ne 0 ]]; then
	exit $ret
fi

echo
echo "Running $OS_NAME ($KERNEL_NAME) on $ARCH"
echo
if [[ $SKIP_VIRTUALBOX -ne 1 ]]; then
	echo "VirtualBox $(vboxmanage --version)"
fi
vagrant --version
echo
echo "Vagrant plugins:"
vagrant plugin list | grep "^vagrant-"
