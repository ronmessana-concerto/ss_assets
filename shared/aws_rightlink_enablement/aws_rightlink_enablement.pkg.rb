###########
# RightLink Enablement Package for AWS
#
# Provides definitions to apply user-data for RightLink enablement to raw instances in AWS.
#
# NOTES AND CAVEATS
# - Only works for Linux Servers.
# - Requires cloud-init to be already installed on the instance(s) being RL enabled.
# - Will RL enable the servers into the calling CAT's deployment.
#

name "AWS RightLink Enablement Package"
rs_ca_ver 20161221
short_description  "Package to RightLink enable one or more AWS raw instances."
long_description "Injects user-data scripts to execute rightlink enablement logic on the instance.
Requires cloud-init to be pre-installed on the raw instances."

package "rl_enable/aws"

# Helpers
import "pft/err_utilities", as: "debug"

# Orchestrate the RightLink enablement process.
# Inputs:
#   @instances - collection of one or more instances
#   server_template_name - name of the ServerTemplate to use when wrapping the instance(s).
#   rs_token_cred_name - name of credential containing the RightScale API refresh token to use when RL enabling.
# Processing:
#   Stops instances.
#   Injects user-data that runs RightLink enablement script.
#   Starts instances.
define rightlink_enable(@instances, $server_template_name, $rs_token_cred_name) do

  # Before doing anything, wait to make sure the instances are operational
  # We don't want to try to stop instances that are not in a stoppable state yet.
  $wake_condition = "/^(operational)$/"
  sleep_until all?(@instances.state[], $wake_condition)

  call stop_instances(@instances) retrieve @stopped_instances

  # Now install userdata that runs RL enablement code
  foreach @instance in @stopped_instances do
    call install_rl_installscript(@instance, $server_template_name, switch(@instance.name==null, @instance.resource_uid, @instance.name), $rs_token_cred_name)
  end

  # Once the user-data is set, start the instance so RL enablement will be run
  call debug.log("starting instances", to_s(to_object(@stopped_instances)))

  call start_instances(@stopped_instances)

end

define stop_instances(@instances) return @stopped_instances do

  # Record instance related data used to find the stopped instances later.
  $num_instances = size(@instances)
  $instance_uids = @instances.resource_uid[]
  @cloud = first(@instances.cloud())

  # Stop the instances
  @instances.stop()

  # Once the instances are stopped they get new HREFs ("next instance"),
  # So, we need to look for the instance check the state until stopped (i.e. provisioned)
  @stopped_instances = rs_cm.instances.empty()
  while size(@stopped_instances) != $num_instances do
    # sleep a bit
    sleep(15)
    @stopped_instances = rs_cm.instances.empty()
    foreach $uid in $instance_uids do
      sub on_error: retry do  # it is possible that between the get on the instanace and the state check that the instance is stopped and the href changes. So just try again
        @instance = @cloud.instances(filter: ["resource_uid=="+$uid])
        if @instance.state == "provisioned"
          @stopped_instances = @stopped_instances + @instance
        end
      end
    end
  end
end

define start_instances(@stopped_instances) do
  $num_instances = size(@stopped_instances)

  # Start the instances.
  @stopped_instances.start()

  # If this is the RL enablement scenario, the instances will automatically appear as
  # servers in the deployment.
  # So wait for them to show up.
  sleep_until(size(@@deployment.servers()) == $num_instances)

  # Now wait until the servers  are in a terminal state
  $wake_condition = "/^(operational|stranded|stranded in booting)$/"
  sleep_until all?(@@deployment.servers().state[], $wake_condition)

end

# Uses EC2 ModifyInstanceAttribute API to install user data that runs RL enablement script
define install_rl_installscript(@instance, $server_template, $servername, $rs_token_cred_name) do

 $instance_id = @instance.resource_uid # needed for the API URL

 # generate the user-data that runs the RL enablement script.
 call build_rl_enablement_userdata($server_template, $servername, $rs_token_cred_name) retrieve $user_data_base64

 # Go tell AWS to update the user-data for the instance
 $url = "https://ec2.amazonaws.com/?Action=ModifyInstanceAttribute&InstanceId="+$instance_id+"&UserData.Value="+$user_data_base64+"&Version=2014-02-01"

 call debug.log("url", $url)

 call get_cred("AWS_ACCESS_KEY_ID") retrieve $access_key
 call get_cred("AWS_SECRET_ACCESS_KEY") retrieve $secret_key

 $signature = {
   "type":"aws",
   "access_key": $access_key, #cred("AWS_ACCESS_KEY_ID"),
   "secret_key": $secret_key #cred("AWS_SECRET_ACCESS_KEY")
   }
 $response = http_post(
   url: $url,
   signature: $signature
   )

  call debug.log("AWS API response", to_s($response))
end

define build_rl_enablement_userdata($server_template_name, $server_name, $rs_refresh_token) return $user_data_base64 do

  call whoami() retrieve $user_id, $account_id, $cm_hostname, $ss_hostname

 # If you look at the RightScale docs, you'll see this line has a sudo before bash, but it's not used here.
 # Since cloud-init runs as root and since the sudo in there may throw the "tty" error, it's really not needed.
 $rl_enablement_cmd = 'curl -s https://rightlink.rightscale.com/rll/10/rightlink.enable.sh | bash -s -- -k "'+cred($rs_token_cred_name)+'" -t "'+$server_template_name+'" -n "'+$server_name+'" -d "'+@@deployment.name+'" -c "amazon" -a "'+$cm_hostname+'"'

 # This sets things up so the script runs on start.
 # Note that the RL enablement script is given a name that should ensure it runs first.
 # This is important if there are other scripts already on the server.
 $user_data = 'Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
cloud_final_modules:
- [scripts-user, always]

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="aaa_rlenable.sh"

#!/bin/bash
'+$rl_enablement_cmd+'
--//'


  # base64 encode the user-data since AWS requires that
  $user_data_base64 = to_base64($user_data)
  # Remove the newlines that to_base64() puts in the result
  $user_data_base64 = gsub($user_data_base64, "
","")
  # Replace any = with html code %3D so the URL is valid.
  $user_data_base64 = gsub($user_data_base64, /=/, "%3D")

end

define get_cred($cred_name) return $cred_value do
  @cred = rs_cm.credentials.get(filter: [ "name=="+$cred_name ], view: "sensitive")
  $cred_hash = to_object(@cred)
  $found_cred = false
  $cred_value = ""
  foreach $detail in $cred_hash["details"] do
    if $detail["name"] == $cred_name
      $found_cred = true
      $cred_value = $detail["value"]
    end
  end

  if logic_not($found_cred)
    raise "Credential with name, " + $cred_name + ", was not found. Credentials are added in Cloud Management on the Design -> Credentials page."
  end
end

define whoami() return $user_id, $account_id, $cm_hostname, $ss_hostname do
  $mapping_shards = {
    "/api/clusters/3": {
      "cm": "us-3.rightscale.com",
      "ss": "selfservice-3.rightscale.com"
    },
    "/api/clusters/4": {
      "cm": "us-4.rightscale.com",
      "ss": "selfservice-4.rightscale.com"
    },
    "/api/clusters/10" => {
      "cm": "telstra-10.rightscale.com",
      "ss": "selfservice-10.rightscale.com"
    }
  }
  $response = rs_cm.session.index(view: 'whoami')
  $whoami_links = $response[0]['links']

  $user_link = last(select($whoami_links, {"rel": "user"}))
  $user_href = $user_link['href']
  $user_id = last(split($user_href, '/'))

  $account_link = last(select($whoami_links, {"rel": "account"}))
  $account_href = $account_link['href']
  $account_id = last(split($account_href, '/'))

  $account_response = rs_cm.get(href: '/api/accounts/'+$account_id)
  $account_links = $account_response[0]['links']

  $shard_link = last(select($account_links, {"rel": "cluster"}))
  $shard_href = $shard_link['href']
  $cm_hostname = map($mapping_shards, $shard_href, 'cm')
  $ss_hostname = map($mapping_shards, $shard_href, 'ss')
end
