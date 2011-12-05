#!/usr/bin/env ruby
STDOUT.sync = true
require 'yaml'
require 'erb'
require 'pp'

# Set to true for lots of verboseness from commands.
DEBUG = false

def gprint(message)
  print "\033[32m#{message}\033[0m"
end

def gputs(message)
  puts "\033[32m#{message}\033[0m"
end

def execwrap(commands, checkretval = false)
  if commands.kind_of?(Array)
    commands.each { |command| execwrap(command,checkretval)}
  elsif commands.kind_of?(String)
    if DEBUG
      system("#{commands}") 
    else
      `#{commands} 2>&1`
    end
    raise "Command failed.\n#{commands}" if (checkretval && $? != 0)
  else
    raise "execwrap only takes an array or string as a first argument"
  end
end

##############################################################################
# Get our constants ready

# Pick up the configuration file off the disk
CONFIG = YAML::load(File.open('config.yml'))

# What is our IP address?
ipaddress = `ip addr show eth0`.scan(/^    inet ([0-9\.]+)\/[0-9]{2}/)[0].to_s

# Which node are we on?
if CONFIG[:primary][:ip] == ipaddress
  ONPRIMARY = true
elsif CONFIG[:secondary][:ip] == ipaddress
  ONPRIMARY = false
else
  raise "Check your config.yml. Your IP addresses don't match this " \
    "instance. This instance has IP #{ipaddress}."
end


##############################################################################
# Confirm what we're going to do

summary = ERB.new <<-END

  Major's MySQL H/A auto-installer
  -----

  Summary:
    This is the <%=(ONPRIMARY) ? "primary" : "secondary" %> node.
    The VIP for this cluster is #{CONFIG[:cluster_details][:vip]}.
    The block device for DRBD is #{CONFIG[:cluster_details][:devicefordrbd]}.
END
puts summary.result
print " \033[31mDo you want to proceed?  Type 'yes' and press enter if so. \033[0m"

input = gets.strip
raise "You didn't say yes. Exiting." if input != "yes"
puts

##############################################################################
# Meat and potatoes

gputs "Adding ssh keys for inter-node tasks... "
execwrap("mkdir -v /root/.ssh")
execwrap("chmod -v 0700 /root/.ssh", true)
privkey = File.open('extras/mysql-autoinstaller_rsa').read
pubkey = File.open('extras/mysql-autoinstaller_rsa.pub').read
sshconfig = ERB.new(File.open('extras/ssh_config.erb').read)
File.open('/root/.ssh/autoinstaller_rsa', 'w') {|f| f.write(privkey) }
File.open('/root/.ssh/authorized_keys', 'w') {|f| f.write(pubkey) }
File.open('/root/.ssh/config', 'w') {|f| f.write(sshconfig.result) }
execwrap("chmod -v 0600 /root/.ssh/*", true)

gputs "Installing drbd8-utils lvm2 rsync... "
execwrap("apt-get -qq update && apt-get -q -y install drbd8-utils lvm2 rsync",true)


blockdev = CONFIG[:cluster_details][:devicefordrbd]
gputs "Creating logical volume on #{blockdev}... "
#DEV: Short circuit
execwrap("pvcreate #{blockdev} && vgcreate vg #{blockdev} && lvcreate -n mysql -l 100%FREE vg", true)


gputs "Writing /etc/hosts & /etc/hostname... "
hostfile = ERB.new(File.open('extras/etc-hosts.erb').read)
File.open('/etc/hosts', 'w') {|f| f.write(hostfile.result) }
hostname = ONPRIMARY ? CONFIG[:primary][:hostname] : CONFIG[:secondary][:hostname]
File.open('/etc/hostname', 'w') {|f| f.write(hostname) }
execwrap("/bin/hostname #{hostname}", true)


gputs "Adding DRBD resource for mysql.. "
drbdresource = ERB.new(File.open('extras/mysql-drbd.erb').read)
File.open('/etc/drbd.d/mysql.res', 'w') {|f| f.write(drbdresource.result) }


gputs "Disabling DRBD usage count reporting... "
execwrap("sed -i 's/usage-count yes;/usage-count no;/' /etc/drbd.d/global_common.conf",true)


gputs "Creating the DRBD resource... "
execwrap("drbdadm -v -f create-md mysql",true)


gputs "Loading DRBD kernel module... "
execwrap("modprobe -v drbd",true)


gputs "Bringing up the mysql DRBD resource... "
execwrap("drbdadm -v up mysql",true)

if ONPRIMARY
  gputs "Overwriting our peer's data... "
  execwrap("drbdadm -v -- --overwrite-data-of-peer primary mysql",true)
  
  gputs "Creating ext3 filesystem on the DRBD device (takes time)... "
  execwrap("mke2fs -j /dev/drbd/by-res/mysql 2>&1",true)
end

gputs "Setting MySQL password in debconf for an automated MySQL installation... "
debconf = <<-EOF
mysql-server-5.1 mysql-server/root_password password temporarypassword
mysql-server-5.1 mysql-server/root_password_again password temporarypassword
mysql-server-5.1 mysql-server/start_on_boot boolean false
EOF
File.open('/tmp/debconf.txt', 'w') {|f| f.write(debconf) }
execwrap("debconf-set-selections < /tmp/debconf.txt")
File.unlink('/tmp/debconf.txt')

gputs "Installing corosync & pacemaker..."
commands = [
  "echo 'deb http://backports.debian.org/debian-backports squeeze-backports main' > /etc/apt/sources.list.d/squeeze-backports.list",
  "apt-get -qq update && apt-get -y -t squeeze-backports install corosync pacemaker"
  ]
execwrap(commands,true)

if ONPRIMARY
  gputs "Creating an authkey for corosync... "
  commands = [
    "apt-get -y install rng-tools",
    "rngd -r /dev/urandom && corosync-keygen",
    "scp /etc/corosync/authkey #{CONFIG[:secondary][:hostname]}:/tmp/authkey",
    "killall rngd",
    "apt-get -y remove rng-tools"
  ]
  execwrap(commands,true)
end

if !ONPRIMARY
  gputs "Ensuring the corosync authkey has come over from the primary node... "
  while true
    break if File.exists?("/tmp/authkey")
    sleep 1
  end
  execwrap("mv -v /tmp/authkey /etc/corosync/authkey",true)
end

gputs "Generating corosync configuration file... "
corosyncconf = ERB.new(File.open("extras/corosync.conf.erb").read)
File.open('/etc/corosync/corosync.conf', 'w') {|f| f.write(corosyncconf.result) }

gputs "Starting corosync... "
execwrap("sed -i 's/START=no/START=yes/' /etc/default/corosync",true)
execwrap("/etc/init.d/corosync start",true)

gputs "Waiting for corosync to settle down (~ 60 seconds or less)... "
while true do
  clusterstatus = `crm_mon -1 -s`
  break if clusterstatus.match(/2 nodes online/)
  sleep 1
end

gputs "Waiting on DRBD to finish its sync (may take a few minutes)... "
while true do 
  drbdstatus = `drbdadm dstate all`
  break if drbdstatus.match(/UpToDate\/UpToDate/)
  sleep 5
end

if (ONPRIMARY)
  gputs "Disabling STONITH... "
  execwrap("crm configure property stonith-enabled=false",true)
  
  gputs "Configuring cluster quorum for two nodes... "
  execwrap("crm configure property no-quorum-policy=ignore")
  
  gputs "Adjusting resource stickiness to prevent failing back... "
  execwrap("crm configure rsc_defaults resource-stickiness=100")
  
  gputs "Adding DRBD to the cluster... "
  execwrap("mkdir -v /var/lib/mysql",true)
  tempcrm = <<-EOF
configure primitive drbd ocf:linbit:drbd params drbd_resource="mysql" op monitor interval="60s"
configure ms drbd_ms drbd meta master-max="1" master-node-max="1" clone-max="2" clone-node-max="1" notify="true" target-role="Master"
configure primitive drbd_fs ocf:heartbeat:Filesystem params device="/dev/drbd/by-res/mysql" directory="/var/lib/mysql" fstype="ext3" op monitor interval="60s"
configure colocation fs_on_drbd inf: drbd_fs drbd_ms:Master
EOF
  File.open('/tmp/crmconfig.tmp', 'w') {|f| f.write(tempcrm) }
  execwrap("crm -f /tmp/crmconfig.tmp",true)

  gputs "Checking to see if the cluster promoted a DRBD master... "
  while true
    crmmon = `crm_mon -1`
    break if (crmmon.match(/Masters: \[ #{CONFIG[:primary][:hostname]} \]/))
    sleep 1
  end

  gputs "Verifying that the mysql DRBD device is mounted... "
  (1..10).each do |i|
    break if `mount | grep mysql`.strip == "/dev/drbd0 on /var/lib/mysql type ext3 (rw)"
    sleep 1
    raise "DRBD mount is missing." if i == 10
  end

  gputs "Installing MySQL... "
  commands = [
      "apt-get -q -y install mysql-client mysql-server",
      "insserv --remove -v mysql",
      "/etc/init.d/mysql stop"
    ]
  execwrap(commands, true)

  gputs "Copying /etc/mysql/debian.cnf to secondary node... "
  execwrap("scp /etc/mysql/debian.cnf #{CONFIG[:secondary][:hostname]}:/tmp/debian.cnf",true)
  
  gputs "Adding the floating IP to the cluster... "
  execwrap(%{crm configure primitive ip ocf:heartbeat:IPaddr2 params ip="#{CONFIG[:cluster_details][:vip]}" cidr_netmask="24" op monitor interval="60s"},true)

  gputs "Adding MySQL, setting a service group, and applying ordering constraints... "
  tempcrm = <<-EOF
configure primitive mysql lsb:mysql meta target-role="Started" op monitor interval="60s"
configure group servicegroup drbd_fs ip mysql meta target-role="Started"
configure order services_order inf: drbd_fs ip mysql
configure order fs_after_drbd inf: drbd_ms:promote servicegroup:start
EOF
  File.open('/tmp/crmconfig.tmp', 'w') {|f| f.write(tempcrm) }
  execwrap("crm -f /tmp/crmconfig.tmp",true)
end

if (!ONPRIMARY)
  gputs "Installing MySQL... "
  commands = [
      "apt-get -q -y install mysql-client mysql-server",
      "insserv --remove -v mysql",
      "/etc/init.d/mysql stop"
    ]
  execwrap(commands, true)

  if !ONPRIMARY
    gputs "Ensuring the /etc/mysql/debian.cnf has come over from the primary node... "
    while true
      break if File.exists?("/tmp/debian.cnf")
      sleep 1
    end
    execwrap("mv -v /tmp/debian.cnf /etc/mysql/debian.cnf",true)
  end

  gputs "Waiting for the primary node to finish up with the cluster configuration... "
  while true
    break if `crm_mon -1 -s`.match(/3 resources configured/)
    sleep 1
  end
end

if ONPRIMARY
  gputs "Generating a self-signed certificate and key for MySQL... "
  execwrap("mkdir -v /etc/mysql/ssl/")
  execwrap(%{openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 -keyout /etc/mysql/ssl/server.key -out /etc/mysql/ssl/server.crt -subj "/C=US/ST=Texas/L=San Antonio/O=My Organization/OU=My Org Unit/CN=#{CONFIG[:cluster_details][:viphostname]}"},true)
  execwrap("rsync -av /etc/mysql/ssl #{CONFIG[:secondary][:hostname]}:/etc/mysql/",true)

  gputs "Ensuring MySQL is up and responding before we secure it... "
  while true do
    break if `mysqladmin ping -u root -ptemporarypassword`.match(/mysqld is alive/)
    sleep 1
  end

  gputs "Securing the MySQL installation... "
  tmpmysql = <<-EOF
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
EOF
  File.open('/tmp/mysqlsecure.sql', 'w') {|f| f.write(tmpmysql) }
  execwrap("mysql -u root -ptemporarypassword < /tmp/mysqlsecure.sql",true)
  File.unlink('/tmp/mysqlsecure.sql')
end

if !ONPRIMARY
  gputs "Waiting for the primary to send over the SSL certificate for MySQL... "
  while true do
    break if File.exists?("/etc/mysql/ssl/server.crt")
  end
end

gputs "Writing the my.cnf and restarting MySQL... "
mysqlconfig = File.open('extras/my.cnf').read
File.open('/etc/mysql/my.cnf', 'w') {|f| f.write(mysqlconfig) }
if ONPRIMARY
  execwrap('crm resource restart mysql',true)
  sleep 5
end

if ONPRIMARY
  gputs "Attempting a failover... "
  execwrap("crm node standby #{CONFIG[:primary][:hostname]}",true)
  sleep 10
  execwrap("crm node online #{CONFIG[:primary][:hostname]}",true)
end

if !ONPRIMARY
  gputs "Waiting for the primary node to attempt a failover... "
  while true do
    break if `crm_mon -1`.match(/Masters: \[ #{CONFIG[:secondary][:hostname]} \]/)
    sleep 1
  end
  
  gputs "Failover started - waiting for the cluster to settle... "
  while true do
    break if `crm_mon -1`.scan(/Started #{CONFIG[:secondary][:hostname]}/).size == 3
    sleep 1
  end
  
  gputs "Verifying DRBD mount... "
  raise "Mount failed." unless `mount | grep mysql`.match(/\/dev\/drbd0/)
  
  gputs "Verifying floating IP... "
  ipaddresses = `ip addr show eth0`.scan(/^    inet ([0-9\.]+)\/[0-9]{2}/).flatten
  raise "Floating IP failed." unless ipaddresses.include?(CONFIG[:cluster_details][:vip])
  
  gputs "Failing back to the primary... "
  execwrap("crm node standby #{CONFIG[:secondary][:hostname]}",true)
  sleep 5
  execwrap("crm node online #{CONFIG[:secondary][:hostname]}",true)
  
  gputs "Removing the ssh keys we added... "
  execwrap('rm -f /root/.ssh/autoinstaller_rsa /root/.ssh/autoinstaller_rsa.pub /root/.ssh/ssh_config')
  
  gputs "<<< ALL DONE >>>"
  gputs "BE SURE TO CHECK THE PRIMARY NODE FOR ADDITIONAL INSTRUCTIONS"
end

if ONPRIMARY
  gputs "Waiting for the secondary node to attempt a failover... "
  while true do
    break if `crm_mon -1`.match(/Masters: \[ #{CONFIG[:primary][:hostname]} \]/)
    sleep 1
  end
  
  gputs "Failover started - waiting for the cluster to settle... "
  while true do
    break if `crm_mon -1`.scan(/Started #{CONFIG[:primary][:hostname]}/).size == 3
    sleep 1
  end
  
  gputs "Removing the ssh keys we added... "
  execwrap('rm -f /root/.ssh/autoinstaller_rsa /root/.ssh/autoinstaller_rsa.pub /root/.ssh/ssh_config')
  
  gputs <<-EOF
------------------------------------------------------------------------------
<<< ALL DONE >>>

  1) Go set a reasonable password for MySQL's root user (currently 'temporarypassword')
EOF
end