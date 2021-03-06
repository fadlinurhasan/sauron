require 'hyperkit'
module Lxd
  extend self

  def add_remote(lxd_host_ipaddress)
    lxd = client(lxd_host_ipaddress)
    begin
      lxd.create_certificate(File.read(lxd.client_cert), password: Figaro.env.CLUSTER_TRUST_PASSWORD)
    rescue StandardError => error
      return {success: false, errors: error.to_s} unless error.to_s.include? "Certificate already in trust store"
    end
    {success: true, errors: ''}
  end

  def list_containers
    container_list = client.containers
    container_list.map {|container| Container.new(container_hostname: container)}
  end

  def show_container(container_name)
    begin
      container_details = client.container(container_name)
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    container_state = client.container_state(container_name)
    ipaddress = container_state&.network&.eth0&.addresses || []
    ipaddress = ipaddress.
      select {|x| x[:family] == 'inet'}.
      first&.address
    container = Container.new(
      container_hostname: container_name,
      status: container_state[:status],
      ipaddress: ipaddress,
      image: container_details[:config][:"image.description"],
      lxc_profiles: container_details[:profiles],
      created_at: container_details[:created_at]
    )
    {success: true, data: container}
  end

  #does not honour image param, will launch 16.04 by default for now.
  def launch_container(image, container_hostname)
    create_container_response = create_container(container_hostname)
    if create_container_response[:success] == 'true'
      StartContainer.perform_async(container_hostname)
    end
    create_container_response
  end

  def create_container(container_hostname)
    begin
      response = client.create_container(container_hostname, server: "https://cloud-images.ubuntu.com/releases", protocol: "simplestreams", alias: "16.04")
      op_response = client.wait_for_operation(response[:id])
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    success = op_response[:status] == 'Success' ? 'true' : false
    {success: success, error: op_response[:err]}
  end

  def start_container(container_hostname)
    begin
      response = client.start_container(container_hostname)
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    success = response[:status] == 'Running' ? 'true' : false
    {success: success, error: response[:err]}
  end

  def destroy_container(container_hostname)
    show_res = show_container(container_hostname)
    is_stopped = (show_res.dig(:data)&.status == "Stopped")
    unless is_stopped
      stop_container_response = stop_container(container_hostname)
    end
    if is_stopped || stop_container_response[:success] == 'true'
      DeleteContainer.perform_in(Figaro.env.WAIT_INTERVAL_FOR_CONTAINER_OPERATIONS, container_hostname)
    end
    stop_container_response
  end

  def stop_container(container_hostname)
    begin
      response = client.stop_container(container_hostname)
      op_response = client.wait_for_operation(response[:id])
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    success = op_response[:status] == 'Success' ? 'true' : false
    {success: success, error: op_response[:err]}
  end

  def recreate_container(container_hostname)
    begin
      show_res = show_container(container_hostname)
      if show_res[:success]
        unless show_res[:data].status == "Stopped"
          stop_res = client.stop_container(container_hostname)
          client.wait_for_operation(stop_res[:id])
        end
        delete_res = client.delete_container(container_hostname)
        client.wait_for_operation(delete_res[:id])
      end

      create_res = client.create_container(container_hostname, server: "https://cloud-images.ubuntu.com/releases", protocol: "simplestreams", alias: "16.04")
      create_op_res = client.wait_for_operation(create_res[:id])
      StartContainer.perform_async(container_hostname) if create_op_res[:status] == 'Success'
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    success = create_op_res[:status] == 'Success' ? 'true' : false
    {success: success, error: create_op_res[:err]}
  end

  def attach_public_key(container_hostname, public_key, opts = {})
    username = opts[:username] || 'ubuntu'

    begin
      response = client.execute_command(container_hostname,
                                        "bash -c 'echo \"#{public_key}\" > /home/#{username}/.ssh/authorized_keys'"
      )
    rescue Hyperkit::Error => error
      return {success: false, error: error.as_json}
    end
    success = response[:status] == 'Success' ? 'true' : false
    {success: success, error: response[:err]}
  end

  def client(lxd_host_ipaddress = ContainerHost.reachable_node)
    Hyperkit::Client.new(api_endpoint: "https://#{lxd_host_ipaddress}:8443", verify_ssl: false, auto_sync: false)
  end

end
