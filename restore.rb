#!/usr/bin/env ruby

require 'rainbow/ext/string'
require 'highline'
require 'json'
require 'tempfile'
require 'csv'
require 'optparse'

$cli = HighLine.new
$docroot = '/srv/git/customers/konecranes/fluid/konecranes/docroot'
$def_src_nids = "887,955,956,957,958,959,960,961,962,964,969,107961,117266,119256,119471,119481,119486,119491,120206,123981,124141"
$exc_langs = "'en', 'en-US'"

$options = {
  :verbose => false,
  :src_nids => $def_src_nids,
  :env => nil,
  :limit => -1,
  :langs => nil,
}

def ask(prompt)
  $cli.ask prompt.color(:yellow)
end

def error(message)
  puts message.color(:red)
end

def local_drush(cmd)
  Dir.chdir $docroot
  debug "drush", "drush #{cmd}"
  `drush #{cmd}`
end

def remote_drush(cmd)
  debug "drush", "drush @konecranes.#{$options[:env]} #{cmd}"
  `drush @konecranes.#{$options[:env]} #{cmd}`
end

def select_env
  $options[:env] = $cli.choose do |menu|
    menu.prompt = "Select the environment to import the nodes to: "
    menu.choices(:dev, :test, :prod)
  end
end

def debug(type, message)
  puts "#{type.upcase.color(:yellow)}: #{message}" if $options[:verbose]
end

def get_missing_nodes
  types_clause = ""

  if $options[:content_types]
    types = $options[:content_types].split(',').map do |type|
      "'#{type}'"
    end
    types_clause = " AND type in (#{types.join(',')}) "
  end

  langs_clause = ""
  if $options[:langs]
    langs = $options[:langs].split(',').map do |lang|
      "'#{lang}'"
    end
    langs_clause = " AND language in (#{langs.join(',')}) "
  end

  query = "SELECT group_concat(nid order by nid asc), count(*) AS count, language, tnid FROM node "\
    " WHERE status=1 AND tnid IN (#{$options[:src_nids]}) AND nid != tnid AND language NOT IN (#{$exc_langs}) #{types_clause} #{langs_clause}"\
    " GROUP BY tnid, language HAVING count >= 1 ORDER BY tnid"

  retval = local_drush "sql-query \"#{query}\""
  nids = []
  info = {}

  retval.split("\n").each do |line|
    parts = line.split "\t"
    nids << parts[0]
    info[parts[0]] = parts
  end

  puts "Found #{nids.size} translated nodes".color(:yellow)

  missing_nids = {}
  existing_nids = remote_drush("sql-query \"select nid from node where nid in (#{nids.join(',')})\"").split("\n")
  existing_nids.each do |nid|
    info.delete(nid)
  end
  puts "There are #{info.size} missing nodes".color(:yellow)
  info
end

def restore_nodes
  nodes = get_missing_nodes
  imported_nodes = 0
  count = 1
  domains = {}
  menu_links_info = {}
  csv_header = nil

  nodes.each do |nid, info|
    # Allow to set a limit for testing
    if $options[:limit] >= 0
      next if count > $options[:limit]
      count += 1
    end

    export = local_drush "node-export-export #{nid} --format=json"
    export = JSON.parse export
    # Reset the tnid to make it a saparate node
    export[0]["tnid"] = 0
    import = JSON.generate export

    puts "Importing node: #{nid}"
    debug "import",  import

    import_file = Tempfile.new("node_import")
    import_file << import
    import_file.close

    retval = `cat #{import_file.path} | drush @konecranes.#{$options[:env]} node-export-import`

    match = /^Imported node ([0-9]+):(.+)$/.match(retval) do |m|
      # Get old node menu info
      row = local_drush "sql-query \"select mlid, menu_name, weight, concat_ws(',', p1, p2, p3, p4, p5) from menu_links where link_path='node/#{nid}' limit 1\""
      cols = row.gsub!("\n", "").split("\t")

      link_titles = local_drush "sql-query \"select group_concat(link_title separator ' --> ') from menu_links where mlid in (#{cols[3]})\""
      link_titles.gsub!("\n", "")

      # Find the domain for this node if not existing
      if not domains[info[2]]
        domain = remote_drush "sql-query \"select domain from languages where language='#{info[2]}'\""
        domains[info[2]] = domain.gsub("\n", "") if not domain.empty?
      end

      node_data = {
        :new_nid => m[1],
        :old_nid => nid,
        :tnid => info[3],
        :language => info[2],
        :title => m[2],
        :menu_name => cols[1],
        :menu_link => link_titles,
        :old_mlid => cols[0],
        :new_mlid => '',
        :menu_weight => cols[2],
        :menu_link_created => false,
        :link => '',
      }

      if domains[info[2]]
        node_data[:link] = "http://#{domains[info[2]]}/node/#{m[1]}"
      end

      if not csv_header
        csv_header = node_data.keys
      end

      # Save this into another hash to create the menu links
      if not menu_links_info[node_data[:menu_name]] 
        menu_links_info[node_data[:menu_name]] = {}
      end

      menu_links_info[node_data[:menu_name]][cols[3]] = node_data
      imported_nodes += 1
    end

    puts retval if not match or $options[:verbose]
  end

  puts menu_links_info.to_s if $options[:verbose]

  menu_links_info.keys.sort.each do |menu_name|
    # Sort the hash by keys so that top level items will be on the top and created first
    menu_links_info[menu_name].keys.sort.each do |menu_plids|
      parent_mlids = menu_plids.split(",")
      parent_mlids.delete("0")
      puts parent_mlids.to_s if $options[:verbose]

      item_info = menu_links_info[menu_name][menu_plids]

      puts "Creating menu link: #{menu_name} -> #{item_info[:menu_link]}: node/#{item_info[:new_nid]}"

      # Now check if the closest parent mlid exists
      last_plid = remote_drush "sql-query \"select mlid from menu_links where menu_name='#{menu_name}' and mlid='#{parent_mlids[-2]}'\""
      last_plid = last_plid.gsub("\n", "")

      # We have all parent mlids, create the menu in hidden state
      if last_plid.to_i > 0
        menu_item_array = "array(\"link_path\" => \"node/#{item_info[:new_nid]}\", \"link_title\" => \"#{item_info[:title]}\",\"weight\" => \"#{item_info[:menu_weight]}\","\
        "\"menu_name\" => \"#{menu_name}\", \"mlid\" => \"#{item_info[:old_mlid]}\", \"plid\" => \"#{last_plid}\", \"hidden\" => \"0\")"

        saved_mlid = remote_drush "eval '$item = #{menu_item_array}; echo menu_link_save($item);'"

        if saved_mlid.to_i > 0 
          menu_links_info[menu_name][menu_plids][:new_mlid] = saved_mlid
          menu_links_info[menu_name][menu_plids][:menu_link_created] = true
        end
      end
    end
  end

  if imported_nodes > 0
    CSV.open('/tmp/result.csv', "wb") do |csv|
      csv << csv_header

      menu_links_info.each do |menu_name, info|
        info.each do |plids, node_info|
          csv << node_info.values
        end
      end
    end

    if $options[:verbose]
      puts "### RESULT ###".color(:yellow)
      File.open('/tmp/result.csv', 'r') do |file|
        puts file.read
      end
    end
  end

  puts "Successfully imported #{imported_nodes} nodes. Result saved to /tmp/result.csv"
end

opt_parser = OptionParser.new do |opts|
  opts.on("-e", "--environment ENV", "Target environment to import to") do |env|
    $options[:env] = env
  end

  opts.on("-l", "--limit COUNT", "Export/import only COUNT nodes. This may be helpful for testing when the node list is long") do |count|
    $options[:limit] = count.to_i
  end

  opts.on("-s", "--source-nids NIDS", "List of source node nids separated by commas") do |nids|
    $options[:src_nids] = nids
  end

  opts.on("-t", "--content-types TYPES", "Content types to work on") do |types|
    $options[:content_types] = types
  end

  opts.on("-n", "--languages LANGS", "Node languages - separated by commas, to work on") do |langs|
    $options[:langs] = langs
  end

  opts.on("-v", "--verbose", "Turn on verbose mode") do
    $options[:verbose] = true
  end
end

opt_parser.parse!

# Environment is required
select_env if not $options[:env]
restore_nodes
