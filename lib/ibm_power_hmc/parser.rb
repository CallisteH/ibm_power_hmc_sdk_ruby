# frozen_string_literal: true

require 'time'
require 'uri'

module IbmPowerHmc
  ##
  # Generic parser for HMC K2 XML responses.
  class Parser
    def initialize(body)
      @doc = REXML::Document.new(body)
    end

    ##
    # @!method entry
    # Return the first K2 entry element in the response.
    # @return [REXML::Element, nil] The first entry element.
    def entry
      @doc.elements["entry"]
    end

    ##
    # @!method object(filter_type = nil)
    # Parse the first K2 entry element into an object.
    # @param filter_type [String] Entry type must match the specified type.
    # @return [IbmPowerHmc::AbstractRest, nil] The parsed object.
    def object(filter_type = nil)
      self.class.to_obj(entry, filter_type)
    end

    def self.to_obj(entry, filter_type = nil)
      return if entry.nil?

      content = entry.elements["content[@type]"]
      return if content.nil?

      type = content.attributes["type"].split("=").last
      return unless filter_type.nil? || filter_type.to_s == type

      Module.const_get("IbmPowerHmc::#{type}").new(entry)
    end
  end

  ##
  # Parser for HMC K2 feeds.
  # A feed encapsulates a list of entries like this:
  # <feed>
  #   <entry>
  #     <!-- entry #1 -->
  #   </entry>
  #   <entry>
  #     <!-- entry #2 -->
  #   </entry>
  #   ...
  # </feed>
  class FeedParser < Parser
    def entries
      objs = []
      @doc.each_element("feed/entry") do |entry|
        objs << yield(entry)
      end
      objs
    end

    ##
    # @!method objects(filter_type = nil)
    # Parse feed entries into objects.
    # @param filter_type [String] Filter entries based on content type.
    # @return [Array<IbmPowerHmc::AbstractRest>] The list of objects.
    def objects(filter_type = nil)
      entries do |entry|
        self.class.to_obj(entry, filter_type)
      end.compact
    end
  end

  private_constant :Parser
  private_constant :FeedParser

  ##
  # HMC generic K2 non-REST object.
  # @abstract
  # @attr_reader [REXML::Document] xml The XML document representing this object.
  class AbstractNonRest
    ATTRS = {}.freeze
    attr_reader :xml

    def initialize(xml)
      @xml = xml
      self.class::ATTRS.each { |varname, xpath| define_attr(varname, xpath) }
    end

    ##
    # @!method define_attr(varname, xpath)
    # Define an instance variable using the text of an XML element as value.
    # @param varname [String] The name of the instance variable.
    # @param xpath [String] The XPath of the XML element containing the text.
    def define_attr(varname, xpath)
      value = singleton(xpath)
      self.class.__send__(:attr_reader, varname)
      instance_variable_set("@#{varname}", value)
    end
    private :define_attr

    ##
    # @!method singleton(xpath, attr = nil)
    # Get the text (or the value of a specified attribute) of an XML element.
    # @param xpath [String] The XPath of the XML element.
    # @param attr [String] The name of the attribute.
    # @return [String, nil] The text or attribute value of the XML element or nil.
    # @example lpar.singleton("PartitionProcessorConfiguration/*/MaximumVirtualProcessors").to_i
    def singleton(xpath, attr = nil)
      elem = xml.elements[xpath]
      return if elem.nil?

      attr.nil? ? elem.text&.strip : elem.attributes[attr]
    end

    def to_s
      str = +"#{self.class.name}:\n"
      self.class::ATTRS.each do |varname, _|
        value = instance_variable_get("@#{varname}")
        value = value.nil? ? "null" : "'#{value}'"
        str << "  #{varname}: #{value}\n"
      end
      str
    end

    def uuid_from_href(href, index = -1)
      URI(href).path.split('/')[index]
    end

    def uuids_from_links(elem, index = -1)
      xml.get_elements("#{elem}/link[@href]").map do |link|
        uuid_from_href(link.attributes["href"], index)
      end.compact
    end
  end

  ##
  # HMC generic K2 REST object.
  # Encapsulate data for a single REST object.
  # The XML looks like this:
  # <entry>
  #   <id>uuid</id>
  #   <published>timestamp</published>
  #   <link rel="SELF" href="https://..."/>
  #   <etag:etag>ETag</etag:etag>
  #   <content type="type">
  #     <!-- actual content here -->
  #   </content>
  # </entry>
  #
  # @abstract
  # @attr_reader [String] uuid The UUID of the object contained in the entry.
  # @attr_reader [Time] published The time at which the entry was published.
  # @attr_reader [URI::HTTPS] href The URL of the object itself.
  # @attr_reader [String] etag The entity tag of the entry.
  # @attr_reader [String] content_type The content type of the object contained in the entry.
  class AbstractRest < AbstractNonRest
    attr_reader :uuid, :published, :href, :etag, :content_type

    def initialize(entry)
      @uuid = entry.elements["id"]&.text
      @published = Time.xmlschema(entry.elements["published"]&.text)
      link = entry.elements["link[@rel='SELF']"]
      @href = URI(link.attributes["href"]) unless link.nil?
      @etag = entry.elements["etag:etag"]&.text&.strip
      content = entry.elements["content"]
      @content_type = content.attributes["type"]
      super(content.elements.first)
    end

    def to_s
      str = super
      str << "  uuid: '#{uuid}'\n"
      str << "  published: '#{published}'\n"
    end
  end

  # HMC information
  class ManagementConsole < AbstractRest
    ATTRS = {
      :name => "ManagementConsoleName",
      :build_level => "VersionInfo/BuildLevel",
      :version => "BaseVersion"
    }.freeze

    def managed_systems_uuids
      uuids_from_links("ManagedSystems")
    end
  end

  # Managed System information
  class ManagedSystem < AbstractRest
    ATTRS = {
      :name => "SystemName",
      :state => "State",
      :hostname => "Hostname",
      :ipaddr => "PrimaryIPAddress",
      :fwversion => "SystemFirmware",
      :memory => "AssociatedSystemMemoryConfiguration/InstalledSystemMemory",
      :avail_mem => "AssociatedSystemMemoryConfiguration/CurrentAvailableSystemMemory",
      :cpus => "AssociatedSystemProcessorConfiguration/InstalledSystemProcessorUnits",
      :avail_cpus => "AssociatedSystemProcessorConfiguration/CurrentAvailableSystemProcessorUnits",
      :mtype => "MachineTypeModelAndSerialNumber/MachineType",
      :model => "MachineTypeModelAndSerialNumber/Model",
      :serial => "MachineTypeModelAndSerialNumber/SerialNumber"
    }.freeze

    def lpars_uuids
      uuids_from_links("AssociatedLogicalPartitions")
    end

    def vioses_uuids
      uuids_from_links("AssociatedVirtualIOServers")
    end

    def io_adapters
      xml.get_elements("AssociatedSystemIOConfiguration/IOSlots/IOSlot/RelatedIOAdapter/IOAdapter").map do |elem|
        IOAdapter.new(elem)
      end
    end

    def vswitches_uuids
      uuids_from_links("AssociatedSystemIOConfiguration/AssociatedSystemVirtualNetwork/VirtualSwitches")
    end

    def networks_uuids
      uuids_from_links("AssociatedSystemIOConfiguration/AssociatedSystemVirtualNetwork/VirtualNetworks")
    end
  end

  # I/O Adapter information
  class IOAdapter < AbstractNonRest
    ATTRS = {
      :id => "AdapterID",
      :description => "Description",
      :name => "DeviceName",
      :type => "DeviceType",
      :dr_name => "DynamicReconfigurationConnectorName",
      :udid => "UniqueDeviceID"
    }.freeze
  end

  # Common class for LPAR and VIOS
  class BasePartition < AbstractRest
    ATTRS = {
      :name => "PartitionName",
      :id => "PartitionID",
      :state => "PartitionState",
      :type => "PartitionType",
      :memory => "PartitionMemoryConfiguration/CurrentMemory",
      :dedicated => "PartitionProcessorConfiguration/HasDedicatedProcessors",
      :rmc_state => "ResourceMonitoringControlState",
      :rmc_ipaddr => "ResourceMonitoringIPAddress",
      :os => "OperatingSystemVersion",
      :ref_code => "ReferenceCode",
      :procs => "PartitionProcessorConfiguration/CurrentDedicatedProcessorConfiguration/CurrentProcessors",
      :proc_units => "PartitionProcessorConfiguration/CurrentSharedProcessorConfiguration/CurrentProcessingUnits",
      :vprocs => "PartitionProcessorConfiguration/CurrentSharedProcessorConfiguration/AllocatedVirtualProcessors"
    }.freeze

    def sys_uuid
      sys_href = singleton("AssociatedManagedSystem", "href")
      uuid_from_href(sys_href)
    end

    def net_adap_uuids
      uuids_from_links("ClientNetworkAdapters")
    end

    def lhea_ports
      xml.get_elements("HostEthernetAdapterLogicalPorts/HostEthernetAdapterLogicalPort").map do |elem|
        HostEthernetAdapterLogicalPort.new(elem)
      end
    end

    def sriov_elp_uuids
      uuids_from_links("SRIOVEthernetLogicalPorts")
    end

    # Setters

    def name=(name)
      xml.elements[ATTRS[:name]].text = name
      @name = name
    end
  end

  # Logical Partition information
  class LogicalPartition < BasePartition
    def vnic_dedicated_uuids
      uuids_from_links("DedicatedVirtualNICs")
    end
  end

  # VIOS information
  class VirtualIOServer < BasePartition
    def pvs
      xml.get_elements("PhysicalVolumes/PhysicalVolume").map do |elem|
        PhysicalVolume.new(elem)
      end
    end

    def rep
      elem = xml.elements["MediaRepositories/VirtualMediaRepository"]
      VirtualMediaRepository.new(elem) unless elem.nil?
    end
  end

  # Empty parent class to match K2 schema definition
  class VirtualSCSIStorage < AbstractNonRest; end

  # Physical Volume information
  class PhysicalVolume < VirtualSCSIStorage
    ATTRS = {
      :location => "LocationCode",
      :description => "Description",
      :is_available => "AvailableForUsage",
      :capacity => "VolumeCapacity",
      :name => "VolumeName",
      :is_fc => "IsFibreChannelBacked",
      :udid => "VolumeUniqueID"
    }.freeze
  end

  # Virtual CD-ROM information
  class VirtualOpticalMedia < VirtualSCSIStorage
    ATTRS = {
      :name => "MediaName",
      :udid => "MediaUDID",
      :mount_opts => "MountType",
      :size => "Size" # in GiB
    }.freeze
  end

  # Virtual Media Repository information
  class VirtualMediaRepository < AbstractNonRest
    ATTRS = {
      :name => "RepositoryName",
      :size => "RepositorySize" # in GiB
    }.freeze

    def vopts
      xml.get_elements("OpticalMedia/VirtualOpticalMedia").map do |elem|
        VirtualOpticalMedia.new(elem)
      end
    end
  end

  # Virtual Switch information
  class VirtualSwitch < AbstractRest
    ATTRS = {
      :id   => "SwitchID",
      :mode => "SwitchMode", # "VEB", "VEPA"
      :name => "SwitchName"
    }.freeze

    def sys_uuid
      href.path.split('/')[-3]
    end

    def networks_uuids
      uuids_from_links("VirtualNetworks")
    end
  end

  # Virtual Network information
  class VirtualNetwork < AbstractRest
    ATTRS = {
      :name       => "NetworkName",
      :vlan_id    => "NetworkVLANID",
      :vswitch_id => "VswitchID",
      :tagged     => "TaggedNetwork"
    }.freeze

    def vswitch_uuid
      href = singleton("AssociatedSwitch", "href")
      uuid_from_href(href)
    end

    def lpars_uuids
      uuids_from_links("ConnectedPartitions")
    end
  end

  # Virtual I/O Adapter information
  class VirtualIOAdapter < AbstractRest
    ATTRS = {
      :type     => "AdapterType", # "Server", "Client", "Unknown"
      :location => "LocationCode",
      :slot     => "VirtualSlotNumber",
      :required => "RequiredAdapter"
    }.freeze
  end

  # Virtual Ethernet Adapter information
  class VirtualEthernetAdapter < VirtualIOAdapter
    ATTRS = ATTRS.merge({
      :macaddr    => "MACAddress",
      :vswitch_id => "VirtualSwitchID",
      :vlan_id    => "PortVLANID",
      :location   => "LocationCode"
    }.freeze)

    def vswitch_uuid
      uuids_from_links("AssociatedVirtualSwitch").first
    end
  end

  # Client Network Adapter information
  class ClientNetworkAdapter < VirtualEthernetAdapter
    def networks_uuids
      uuids_from_links("VirtualNetworks")
    end
  end

  # LP-HEA information
  class EthernetBackingDevice < IOAdapter; end
  class HostEthernetAdapterLogicalPort < EthernetBackingDevice
    ATTRS = ATTRS.merge({
      :macaddr  => "MACAddress",
      :port_id  => "LogicalPortID",
      :state    => "PortState",
      :location => "HEALogicalPortPhysicalLocation"
    }.freeze)
  end

  # Virtual NIC dedicated information
  class VirtualNICDedicated < VirtualIOAdapter
    ATTRS = ATTRS.merge({
      :location     => "DynamicReconfigurationConnectorName", # overrides VirtualIOAdapter
      :macaddr      => "Details/MACAddress",
      :os_devname   => "Details/OSDeviceName",
      :port_vlan_id => "Details/PortVLANID"
    }.freeze)
  end

  # SR-IOV Configured Logical Port information
  class SRIOVConfiguredLogicalPort < AbstractRest
    ATTRS = {
      :port_id      => "LogicalPortID",
      :port_vlan_id => "PortVLANID",
      :location     => "LocationCode",
      :dr_name      => "DynamicReconfigurationConnectorName",
      :devname      => "DeviceName",
      :capacity     => "ConfiguredCapacity"
    }.freeze

    def lpars_uuids
      uuids_from_links("AssociatedLogicalPartitions")
    end
  end

  # SR-IOV Ethernet Logical Port information
  class SRIOVEthernetLogicalPort < SRIOVConfiguredLogicalPort
    ATTRS = ATTRS.merge({
      :macaddr => "MACAddress"
    }.freeze)
  end

  # Cluster information
  class Cluster < AbstractRest
    ATTRS = {
      :name => "ClusterName",
      :id => "ClusterID",
      :tier_capable => "ClusterCapabilities/IsTierCapable"
    }.freeze

    def ssp_uuid
      href = singleton("ClusterSharedStoragePool", "href")
      uuid_from_href(href)
    end

    def nodes
      xml.get_elements("Node/Node").map do |elem|
        Node.new(elem)
      end
    end
  end

  # Cluster node information
  class Node < AbstractNonRest
    ATTRS = {
      :hostname => "HostName",
      :lpar_id => "PartitionID",
      :state => "State",
      :ioslevel => "VirtualIOServerLevel"
    }.freeze

    def vios_uuid
      href = singleton("VirtualIOServer", "href")
      uuid_from_href(href)
    end
  end

  # SSP information
  class SharedStoragePool < AbstractRest
    ATTRS = {
      :name => "StoragePoolName",
      :udid => "UniqueDeviceID",
      :capacity => "Capacity",
      :free_space => "FreeSpace",
      :overcommit => "OverCommitSpace",
      :total_lu_size => "TotalLogicalUnitSize",
      :alert_threshold => "AlertThreshold"
    }.freeze

    def cluster_uuid
      href = singleton("AssociatedCluster", "href")
      uuid_from_href(href)
    end

    def pvs
      xml.get_elements("PhysicalVolumes/PhysicalVolume").map do |elem|
        PhysicalVolume.new(elem)
      end
    end

    def tiers_uuids
      uuids_from_links("AssociatedTiers")
    end

    def lus
      xml.get_elements("LogicalUnits/LogicalUnit").map do |elem|
        LogicalUnit.new(elem)
      end
    end
  end

  # SSP tier information
  class Tier < AbstractRest
    ATTRS = {
      :name => "Name",
      :udid => "UniqueDeviceID",
      :type => "Type",
      :capacity => "Capacity",
      :total_lu_size => "TotalLogicalUnitSize",
      :is_default => "IsDefault",
      :free_space => "FreeSpace"
    }.freeze

    def ssp_uuid
      href = singleton("AssociatedSharedStoragePool", "href")
      uuid_from_href(href)
    end

    def lus_uuids
      uuids_from_links("AssociatedLogicalUnits")
    end
  end

  # SSP LU information
  class LogicalUnit < VirtualSCSIStorage
    ATTRS = {
      :name => "UnitName",
      :capacity => "UnitCapacity",
      :udid => "UniqueDeviceID",
      :thin => "ThinDevice",
      :type => "LogicalUnitType",
      :in_use => "InUse"
    }.freeze
  end

  class PartitionTemplateSummary < AbstractRest
    ATTRS = {
      :name => "partitionTemplateName"
    }.freeze
  end

  class PartitionTemplate < AbstractRest
    ATTRS = {
      :name => "partitionTemplateName"
    }.freeze
  end

  # HMC Event
  class Event < AbstractRest
    attr_accessor :usertask
    ATTRS = {
      :id     => "EventID",
      :type   => "EventType",
      :data   => "EventData",
      :detail => "EventDetail"
    }.freeze
  end

  # Error response from HMC
  class HttpErrorResponse < AbstractRest
    ATTRS = {
      :status  => "HTTPStatus",
      :uri     => "RequestURI",
      :reason  => "ReasonCode",
      :message => "Message"
    }.freeze
  end

  # Job Response
  class JobResponse < AbstractRest
    ATTRS = {
      :id      => "JobID",
      :status  => "Status",
      :message => "ResponseException/Message"
    }.freeze

    def results
      results = {}
      xml.each_element("Results/JobParameter") do |jobparam|
        name = jobparam.elements["ParameterName"]&.text&.strip
        value = jobparam.elements["ParameterValue"]&.text&.strip
        results[name] = value unless name.nil?
      end
      results
    end
  end
end
