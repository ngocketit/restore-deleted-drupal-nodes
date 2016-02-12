#!/usr/bin/env ruby

require 'rainbow/ext/string'
require 'highline'
require 'json'
require 'tempfile'
require 'csv'
require 'optparse'

$cli = HighLine.new
$local_docroot = nil # Put here local docroot if you don't want to be prompted
$def_src_nids = nil # Put here default source node ids separated by commas

$options = {
  :site_name => nil,
  :verbose => false,
  :src_nids => $def_src_nids,
  :src_env => nil,
  :target_env => nil,
  :limit => -1,
  :langs => nil,
}

def ask(prompt)
  $cli.ask prompt.color(:yellow) do |q|
    yield q if block_given?
  end
end

def info(message)
  puts message.color(:green)
end

def error(message)
  puts message.color(:red)
end

def fatal_error(message)
  error message
  exit
end

def drush(env, cmd)
  drush_alias = ''
  if $options[env] == :local
    Dir.chdir $local_docroot
  else
    drush_alias = "@#{$options[:site_name]}.#{$options[env]}"
  end
  debug "drush", "drush #{drush_alias} #{cmd}"
  `drush #{drush_alias} #{cmd}`
end

def source_drush(cmd)
  drush :src_env, cmd
end

def target_drush(cmd)
  drush :target_env, cmd
end

def module_exists?(env, module_name)
  output = drush env, "pm-info #{module_name}"
  exists = false
  if matches = output.match(/Status\s*:\s*(enabled|disabled|not installed)\s*/)
    exists = matches[1] == 'enabled'
  end
  exists
end

def select_site_name
  drush_folder = File.expand_path('~/.drush')
  if not File.directory? drush_folder
    error "Drush folder #{drush_folder} not exist. Abort!"
    exit
  end

  aliases = []
  Dir[File.join(drush_folder, '*.aliases.drushrc.php')].each do |drush_file|
    aliases << File.basename(drush_file).gsub('.aliases.drushrc.php', '')
  end

  if aliases.empty?
    error "There is no Acquia Drush aliases on your system. Please download them from Acquia Cloud and put them into #{drush_folder}"
    exit
  end

  $options[:site_name] = $cli.choose do |menu|
    menu.prompt = "Select the site name: ".color(:yellow)
    menu.choices(*aliases)
  end
end

def select_env(prompt)
  $cli.choose do |menu|
    menu.prompt = prompt.color(:yellow)
    menu.choices(:local, :dev, :test, :prod)
  end
end

def select_src_env
  $options[:src_env] = select_env "Select the source environment from which to import the missing nodes: "
end

def select_target_env
  $options[:target_env] = select_env "Select the target environment where missing nodes are imported to: "
end

def prompt_source_nids
  $options[:src_nids] = ask "Enter the nid of the source nodes separated by commans: " do |q|
    q.validate = /[0-9, ]+/
  end
end

def prompt_langs
  $options[:langs] = ask "Enter the language codes of the nodes you want to import (press Enter to skip and ignore language): "
end

def debug(type, message)
  puts "#{type.upcase.color(:yellow)}: #{message}" if $options[:verbose]
end

def check_environments
  if $options[:src_env] == $options[:target_env]
    fatal_error "Source and target environment can't be the same. Abort!"
  end

  if $options[:src_env] == :local or $options[:target_env] == :local
    $local_docroot = ask "What is local docroot? "
    if not File.directory?($local_docroot)
      fatal_error "Local docroot #{$local_docroot} not exists. Abort"
    end
  end
end

def check_requirements
  info "Checking requirements on source & target environments"

  if not module_exists? :src_env, 'node_export'
    fatal_error "node_export module needs to be installed on source environment. Abort!"
  else
    info "Source enviroment: OK"
  end

  if not module_exists? :target_env, 'node_export'
    fatal_error "node_export module needs to be installed on target environment. Abort!"
  else
    info "Target enviroment: OK"
  end
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
    " WHERE status=1 AND tnid IN (#{$options[:src_nids]}) AND nid != tnid #{types_clause} #{langs_clause}"\
    " GROUP BY tnid, language HAVING count >= 1 ORDER BY tnid"

  retval = source_drush "sql-query \"#{query}\""
  nids = []
  node_info = {}

  retval.split("\n").each do |line|
    parts = line.split "\t"
    nids << parts[0]
    node_info[parts[0]] = parts
  end

  info "Found #{nids.size} translated nodes"

  missing_nids = {}
  existing_nids = target_drush("sql-query \"select nid from node where nid in (#{nids.join(',')})\"").split("\n")
  existing_nids.each do |nid|
    node_info.delete(nid)
  end
  info "Found #{node_info.size} missing nodes"
  node_info
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

    export = source_drush "node-export-export #{nid} --format=json"
    export = JSON.parse export
    # Reset the tnid to make it a saparate node
    export[0]["tnid"] = 0
    import = JSON.generate export

    info "Importing node: #{nid}"
    debug "import",  import

    import_file = Tempfile.new("node_import")
    import_file << import
    import_file.close

    retval = `cat #{import_file.path} | drush @#{$options[:site_name]}.#{$options[:target_env]} node-export-import`

    match = /^Imported node ([0-9]+):(.+)$/.match(retval) do |m|
      # Get old node menu info
      row = source_drush "sql-query \"select mlid, menu_name, weight, concat_ws(',', p1, p2, p3, p4, p5) from menu_links where link_path='node/#{nid}' limit 1\""
      cols = row.gsub!("\n", "").split("\t")

      link_titles = source_drush "sql-query \"select group_concat(link_title separator ' --> ') from menu_links where mlid in (#{cols[3]})\""
      link_titles.gsub!("\n", "")

      # Find the domain for this node if not existing
      if not domains[info[2]]
        domain = target_drush "sql-query \"select domain from languages where language='#{info[2]}'\""
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

      info "Creating menu link: #{menu_name} -> #{item_info[:menu_link]}: node/#{item_info[:new_nid]}"

      # Now check if the closest parent mlid exists
      last_plid = target_drush "sql-query \"select mlid from menu_links where menu_name='#{menu_name}' and mlid='#{parent_mlids[-2]}'\""
      last_plid = last_plid.gsub("\n", "")

      # We have all parent mlids, create the menu in hidden state
      if last_plid.to_i > 0
        menu_item_array = "array(\"link_path\" => \"node/#{item_info[:new_nid]}\", \"link_title\" => \"#{item_info[:title]}\",\"weight\" => \"#{item_info[:menu_weight]}\","\
        "\"menu_name\" => \"#{menu_name}\", \"mlid\" => \"#{item_info[:old_mlid]}\", \"plid\" => \"#{last_plid}\", \"hidden\" => \"0\")"

        saved_mlid = target_drush "eval '$item = #{menu_item_array}; echo menu_link_save($item);'"

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

  info "Restored #{imported_nodes} nodes. Result saved to /tmp/result.csv"
end

opt_parser = OptionParser.new do |opts|
  opts.on("-s", "--sitename SITE", "Name of Acquia Cloud site") do |site|
    $options[:site_name] = site
  end

  opts.on("-r", "--source-env ENV", "Source environment to import from") do |env|
    $options[:src_env] = env
  end

  opts.on("-t", "--target-env ENV", "Target environment to import to") do |env|
    $options[:target_env] = env
  end

  opts.on("-l", "--limit COUNT", "Export/import only COUNT nodes. This may be helpful for testing when the node list is long") do |count|
    $options[:limit] = count.to_i
  end

  opts.on("-n", "--source-nids NIDS", "List of source node nids separated by commas") do |nids|
    $options[:src_nids] = nids
  end

  opts.on("-c", "--content-types TYPES", "Content types to work on") do |types|
    $options[:content_types] = types
  end

  opts.on("-g", "--languages LANGS", "Node languages - separated by commas, to work on") do |langs|
    $options[:langs] = langs
  end

  opts.on("-v", "--verbose", "Turn on verbose mode") do
    $options[:verbose] = true
  end
end

opt_parser.parse!

select_site_name if not $options[:site_name]
select_src_env if not $options[:src_env]
select_target_env if not $options[:target_env]

check_environments
check_requirements

prompt_source_nids if not $options[:src_nids]
prompt_langs if not $options[:langs]

restore_nodes
