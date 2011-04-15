#!/usr/bin/env ruby
require 'rubygems'
require 'fog'
require 'dnsruby'

### CONSTANTS FOR YOU TO CHANGE --> 
ZONES_DIR  = '/etc/bind/'
AWS_KEY_ID = "REPLACE WITH AWS KEY ID"
AWS_SECRET = "REPLACE WITH AWS SECRET"
### <---

zone_file = ARGV[0]  #example.com.db
origin    = ARGV[1]  #example.com

#first check to see if the zone is in AWS
dns = Fog::AWS::DNS.new(
  :aws_access_key_id => AWS_KEY_ID,
  :aws_secret_access_key => AWS_SECRET 
)

#compare the names of the AWS-managed zones to the name of the zone supplied ARGV[1]
the_zone = nil
dns.zones.each{|zone|
  if(zone.domain.chop == origin)
	the_zone = zone	
  end  
}

#if the zone is managed
if(!the_zone.nil?)
  puts "Found an AWS zone for #{origin}. It is zone id : #{the_zone.id}"
#if the zone is not managed by AWS -- see if we should create it?
else
  puts "Did not find a zone for #{origin}. Do you want to create one? (y/n)"
  create = ((STDIN.gets.chomp||'y') == 'y')
  if(create)
	hosted_zone_response = dns.create_hosted_zone(origin)
  	puts "Here is response on creating hosted zone:"
  	puts hosted_zone_response.inspect
  	the_zone = dns.zones.select{|z| z.id == hosted_zone_response.body['HostedZone']['Id']}.first
  else
       puts "Exiting now"
       exit
  end
end

#read local zone file (supplied as ARGV[0])
zone_reader = Dnsruby::ZoneReader.new(origin)
records     = zone_reader.process_file("#{ZONES_DIR}#{zone_file}")

#only proceed if there are records found locally
if(!records.nil? and records.length > 0)
   
   #print out what is currently in AWS zone
   aws_records = the_zone.records.select{|record| record.type != "SOA" and record.type != "NS"}
   puts
   puts "Found the following records in AWS Zone #{the_zone.id}"
   if(aws_records.nil? or aws_records.empty?)
	puts "Empty"
   end 
  
   #as we iterate, build our 'delete' record hash 
   change_batch_deleted_hash = {}
   aws_records.each{|record|
      record.ip.each{|ip|
        puts "#{record.name} #{record.ttl} IN #{record.type} #{ip}"
       }
      rr = record.attributes.delete(:ip)
      change_delete = {:action => 'DELETE'}.merge(record.attributes.merge({:resource_records => rr}))
      change_batch_deleted_hash["#{record.name.downcase}-#{record.type}"] = change_delete
   }

   #print out what we find in local zone file
   puts 
   puts "Found the following records in local zone '#{zone_file}'"
   local_records = records.select{|record| record.type != "SOA" and record.type != "NS"}
   change_batch_created_hash = {}
   puts
   puts "Records:"
   local_records.each{|record|
      change_create = {:action => 'CREATE', :name => "#{record.name.to_s}.", :type => "#{record.type}", :ttl => record.ttl, :resource_records => ([]<<"#{record.rdata.to_s}")}
      puts "#{record.name.to_s} #{record.ttl} IN #{record.type} #{record.rdata.to_s}" 
      if(already_processed_hash = change_batch_created_hash["#{record.name.to_s}.-#{record.type}"])
	already_processed_hash[:resource_records] << "#{record.rdata.to_s}"
        change_batch_created_hash["#{record.name.to_s}.-#{record.type}"] = already_processed_hash
      else
	change_batch_created_hash["#{record.name.to_s}.-#{record.type}"] = change_create
      end
      #change_batch_deleted_hash.delete("#{record.name.to_s.downcase}.")
   }
  change_batch = change_batch_deleted_hash.values.concat(change_batch_created_hash.values.select{|change| change[:type] != "SOA" and change[:type] != "NS"})
  puts
  puts "Proceed with changes?(y/n)"
  if(STDIN.gets.chomp == 'y')
	change_batch.each{|change| puts "Here is a change: #{change.inspect}"}
  	 #dns.change_resource_record_sets(the_zone.id, change_batch, {"comment" => "initial migration from bind"})
  	 puts "Here are the details of the zone you have updated: "
  	 puts the_zone.inspect
  	end
  end

