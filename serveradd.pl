#!/usr/bin/perl

#
# Creates an AWS instance, adds infrastructure, and a web server from a single script execution
# Prerequisites:
# Amazon CLI EC2 Tools Installed
# CPAN installed
# AWS account Access Key and Secret Access keys
#

use strict;

## Set some variables
my $ami = 'ami-1ecae776'; #Amazon base Linux AMI
my $size = 't2.micro';
my $baseName = 'serverInstance';
my $myAddress = '0.0.0.0'; 
my $launchVPC;
my $securityGroup;
my $instanceId;
my $cnt = 0; #number of status check attempts
my $multi = 20; #seconds between status checks
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =localtime(time);
$year += 1900;
my $baseUniqueName = "$baseName$year$mon$mday$hour$min$sec";


sub installNetSSHPerl
{
	return (`sudo curl -L http://cpanmin.us | perl - --sudo Net::OpenSSH`);
}

sub setEnv
{
	## Get some access keys from user
	my $accessKey = prompt('Enter Your AWS Access Key [20 Characters] :');
	my $secretAccessKey = prompt('Enter Your AWS Secret Access Key [40 Characters] :');
	$ENV{AWS_ACCESS_KEY}=$accessKey;
	$ENV{AWS_SECRET_KEY}=$secretAccessKey;
	return ($ENV{AWS_ACCESS_KEY} && $ENV{AWS_SECRET_KEY});
}

sub prompt 
{
	my $promptName = shift;
	print "$promptName";
	my $input = <STDIN>;
	return $input;
}

sub createKey 
{
	my ($baseUniqueName) = @_;
	my $key = `ec2-create-keypair $baseUniqueName`;	
	
	if($key =~ /^.*\n(-----BEGIN)((.*\n)*)(-----END RSA PRIVATE KEY-----)/g)
	{
		$key = "$1$2$4";
	}
	else
	{
		print "ERROR: Unable to create a key pair in EC2, please check that the ACCESS_KEY and SECRET_ACCESS_KEY that were provided are correct.\n";
		exit 1;
	}
	if($key =~ /^-----BEGIN/g && $key =~ /KEY-----/g)
	{
		open (KEY,">","./$baseUniqueName.pem");
		print KEY $key;
		close (KEY);
		system("chmod 400 ./$baseUniqueName.pem");
	}
	else
	{
		print "ERROR: Key pair is improperly formatted. Please check that your AWS Tools are configured correctly.\n";
		exit 1;
	}
	return 1;
}

sub getDefaultVPC
{
	my $vpc = `ec2-describe-vpcs --filter "isDefault=true"`;
	my $vpcId;
	$vpcId = $1 if ($vpc =~ /^.*(vpc-.{8}).*$/);
	$vpcId = undef if(!($vpcId =~ /^vpc-.{8}$/));
	return $vpcId;
}

sub getAvailSubnet
{
	my $vpc = shift;
	my $subnetId;
	my @subnets = `ec2-describe-subnets --filter "vpc-id=$vpc" --filter "state=available"`;
	$subnetId = $1 if ($subnets[0] =~ /^.*(subnet-.{8}).*$/);
	$subnetId = undef if(!($subnetId =~ /^subnet-.{8}$/));
	return $subnetId;
}

sub createSecurityGroup
{
	my ($baseUniqueName,$launchVPC,$myCIDRAddress) =@_;
	$securityGroup = `ec2-create-group $baseUniqueName -d "Web Instance $baseUniqueName" -c $launchVPC`;
	
	$securityGroup = $1 if ($securityGroup =~ /^.*(sg-.{8}).*$/);
	$securityGroup = undef if(!($securityGroup =~ /^sg-.{8}$/));
	if($securityGroup)
	{
		`ec2-authorize $securityGroup -P tcp -p 80 -s $myCIDRAddress`;
		`ec2-authorize $securityGroup -P tcp -p 22 -s $myCIDRAddress`;
	}
	else
	{
		print "ERROR: Could not create a security group ... exiting.\n";
		exit 1;
	}
	return $securityGroup;
}

sub createInstance
{
	my ($ami,$size,$subnet,$keyName,$securityGroup) = @_;
	my $instance = `ec2-run-instances $ami -t $size -s $subnet -k $keyName -g $securityGroup --associate-public-ip-address true`;
	$instance = $1 if ($instance =~ /^.*\nINSTANCE\t(i-.{8}).*$/s);
	$instance = undef if(!($instance =~ /^i-.{8}$/));
	return $instance;
}

sub getPublicDNSName
{
	my ($instance) = @_;
	my $instanceInfo = `ec2-describe-instances $instance`;
	my $publicDNSName;
	$publicDNSName = $1 if ($instanceInfo =~ /(ec2-.*.compute-1.amazonaws.com)/g);
	print "INFO: Public DNS Name: $publicDNSName\n";
	return $publicDNSName;
}
sub configureInstance
{
	my ($publicDNS,$key) = @_;
	
	my $userConnection = 'ec2-user@' . $publicDNS;
  	my $ssh = Net::OpenSSH->new($userConnection , key_path => "./$key", master_opts => [ -o => "StrictHostKeyChecking=no"]);
  	$ssh->error and die "ERROR: Couldn't establish SSH connection: ". $ssh->error;
    
    ## Update our system before begining
     my $result = $ssh->system({ timeout => 10,tty=>1},"sudo yum update -y");
	print "INFO: Remote yum update completed.\n";
	
	 ## Install Amazon's Apache2.4
     my $output = $ssh->capture({ timeout => 10,tty=>1},"sudo yum install -y httpd24");
     print $output;
     print "INFO: Remote apache2 install completed.\n";

	 ## Write a new index.thml
     $output = $ssh->capture({ timeout => 10,tty=>1},"sudo echo '<html><bod><h2><b>Automation for the People</h2></body></html>' >  index.html");
     print $output;
     
     ## Move the new index.html file to it's home
     $output = $ssh->capture({ timeout => 10,tty=>1},"sudo mv index.html /var/www/html ");
     print $output;
     print "INFO: Remote index.html file creation completed.\n";
     
     ## Set the apache2 server to initiate on start-up
     $output = $ssh->capture({ timeout => 10,tty=>1},"sudo chkconfig httpd on");
     print $output;
     print "INFO: Remote chkconfig httpd completed.\n";
     
     ## Note: reboot is only necessary because Net::OpenSSH does not seem to allow a clean start of apache2
     $output = $ssh->capture({ timeout => 10,tty=>1},"sudo reboot");
     print $output;
     print "INFO: Rebooting the server to start httpd server.\n";
     sleep 60;
     print "INFO: Server instance was successfully installed. You can reach the new web page at http://$publicDNS in your browser.";
}

sub isRunning
{	
	my ($instance,$cnt) = @_;
	if ($cnt > 20)
	{
		print "ERROR: More than 20 attempts were made to get a running status from $instance ... aborting.";
		exit 1;
	}
	return `ec2-describe-instance-status $instance --filter "system-status.reachability=passed"`;	
}


## Start Instance Creation
if  (eval { require Net::OpenSSH;Net::OpenSSH->import();1;}) 
{
	print "INFO: Net::OpenSSH is installed proceeding.\n"
}
else
{	print "INFO: Attempting to install Net:OpenSSH.\n";
	if(!(installNetSSHPerl()))
	{
		print "ERROR: Perl module Net::SSH::Perlcould not be installed programmatically.  Please install the module via CPAN and try the script installation again.\n";
		exit 1;
	}
	print "INFO: Successfully installed Net:OpenSSH.\n";
	if  (eval { require Net::OpenSSH;Net::OpenSSH->import();1;}) 
	{
		print "INFO: Net::OpenSSH is installed proceeding.\n"
	}
	else
	{
		print "ERROR: Perl module Net::SSH::Perlcould not be installed programmatically.  Please install the module via CPAN and try the script installation again.\n";
		exit 1;
	}
}


if(!($ENV{AWS_ACCESS_KEY} && $ENV{AWS_SECRET_KEY}))
{
 	if(!setEnv())
 	{
 		print "ERROR: Could not set environment variables.\n";
 	}
}


if(createKey($baseUniqueName))
{
	print "KEY $baseUniqueName.pem was created.\n";
	my $error;
	if(!$launchVPC)
	{
	 	 $launchVPC = getDefaultVPC();
 	 	print "VPC $launchVPC is the destination for this launch.\n";
	}
	if ($launchVPC =~ /vpc-.{8}/)
	{
		$securityGroup = createSecurityGroup($baseUniqueName,$launchVPC,"$myAddress/0");
		print "SecurityGroup $securityGroup is the newly created security group for this installation.\n";
	}
	else
	{
	 	print "ERROR: Could not determine a launch VPC.\n";
	 	exit 1;
	}
	if ($securityGroup =~ /sg-.{8}/)
	{
		my $subnet = getAvailSubnet($launchVPC);
		print "Subnet $subnet is the retrieved subnet.\n";
		$instanceId = createInstance($ami,$size,$subnet,"$baseUniqueName",$securityGroup);
		print "Instance $instanceId is the launched instance.\n";
	}
	else
	{
		$error = "ERROR: Could not determine a launch security group.";
	}
	while(!isRunning($instanceId,++$cnt))
	{
		sleep $multi;
		print "INSTANCE Starting " . ($cnt * $multi) . " seconds ...\n";
	}
	sleep 20;
	print "INSTANCE Start Completed " . ($cnt * $multi) . " seconds.\n";
	if ($instanceId)
	{
		my $dnsname = getPublicDNSName($instanceId);
		configureInstance($dnsname,"$baseUniqueName.pem");
	}
}
