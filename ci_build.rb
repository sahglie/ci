#!/usr/bin/env ruby

require 'rubygems'
require 'fileutils'
require 'warbler'

class CiBuild
  attr_accessor :svn_url, :workspace, :db_adapter, :run_specs, :precompile_assets

  def initialize(svn_url, workspace, options={})
    @svn_url = svn_url
    @workspace = workspace
    $stdout.puts(workspace)

    @db_adapter = options.fetch(:adapter) { "postgresql" }
    @run_specs = options.fetch(:run_specs) { true }
    @precompile_assets = options.fetch(:precompile_assets) { true }
  end

  def run
    Dir.chdir(workspace) do
      remove_workspace_rvm_config
      run_bundle_install
      setup_dot_yml_files
      setup_db
      run_rspec_suite
      compile_assets
      check_in_war_file
    end
  end


  private

  def remove_workspace_rvm_config
    FileUtils.rm_rf("#{workspace}/.rvmrc") if File.exists?("#{workspace}/.rvmrc")
  end

  def app_name
    unless @app_name
      parts = svn_url.split("/")
      @app_name = parts[4]
    end
    @app_name
  end

  def svn_wars_url
    [svn_root_url, "wars"].join("/")
  end

  def svn_root_url
    unless @svn_root_url
      parts = svn_url.split("/")
      @svn_root_url = parts[0..4].join("/")
    end
    @svn_root_url
  end

  def war_name
    unless @war_name
      @war_name = svn_url.split("/").pop
    end
    @war_name
  end

  def default_env_vars
    [ "WEBKIT=false", "QMAKE=/usr/bin/qmake-qt47" ]
  end

  def run_cmd(cmd, env_vars = [])
    # TODO: Enable after qt47 is installed
    # env = (default_env_vars + env_vars).join(" ")

    env = env_vars.join(" ")
    full_cmd = "#{env} #{cmd}"
    $stdout.puts("#{full_cmd} ... ")

    output = `#{full_cmd} 2>&1`
    $stdout.puts(output)

    if $?.success?
      $stdout.puts("[OK]")
    else
      $stdout.puts("[FAILED]")
      $stdout.puts($?.exitstatus)
      exit($?.exitstatus)
    end

    output
  end

  def run_bundle_install
    run_cmd("bundle install")
  end

  def db_name
    [app_name, war_name].join("_")
  end

  def setup_dot_yml_files
    create_db_yml
    Dir.glob("config/*.yml.example").each do |file_path|
      file_name = File.basename(file_path).split(".")[0..1].join(".")
      next if file_name == "database.yml"
      dir_name = File.dirname(file_path)
      FileUtils.cp(file_path, File.join(dir_name, file_name))
    end
  end

  def setup_db
    return unless run_specs
    run_cmd("bundle exec rake db:migrate", ["RAILS_ENV=test"])
    # Rails.env = "test"
    # Rake::Task['db:create'].invoke unless db_adapter == 'sqlite3'
    # Rake::Task['db:migrate'].invoke
  end

  def create_db_yml
    db_yml_contents = <<-DB
test: &test
   adapter: #{db_adapter}
   database: #{db_name}
   username: jenkins
   password: jenkins
   host: localhost

ci:
   <<: *test
DB
    File.open("config/database.yml", "w") do |f|
      f.write(db_yml_contents)
    end
  end

  def run_rspec_suite
    return unless run_specs
    run_cmd("bundle exec rspec spec --tag ~js --format RspecJunitFormatter --out results.xml", ["RAILS_ENV=test"])
  end

  def check_in_war_file
    create_war
    remove_war if war_checked_in?
    commit_war
  end

  def compile_assets
    cache_compiled_assets
    return unless precompile_assets
    run_cmd("bundle exec rake assets:precompile", ["RAILS_ENV=ci"])
  end

  def cache_compiled_assets
    tokens = workspace.split("/")
    tokens.pop
    dir = tokens.pop

    link = "#{ENV['HOME']}/.jenkins/jobs/#{dir}/workspace/tmp"
    target = "#{ENV['HOME']}/tmp/#{dir}"

    FileUtils.mkdir(target) unless File.exists?(target)
    FileUtils.rm_rf(link) if File.exists?(link)
    File.symlink(target, link) unless File.symlink?(link)
  end

  def create_war
    RakeFileUtils.verbose_flag = true
    Warbler::Task.new('trunk')

    $stdout.print("Building war file: ")
    Rake::Task['trunk'].invoke()

    FileUtils.mv("workspace.war", "#{war_name}.war")
  end

  def war_checked_in?
    wars = run_cmd("svn list #{svn_wars_url}").split("\n")
    wars.include?("#{war_name}.war")
  end

  def remove_war
    run_cmd("svn rm #{svn_wars_url}/#{war_name}.war -m 'removing war #{war_name}.war' &")
    run_cmd("sleep 2s")
  end

  def commit_war
    run_cmd("svn import #{war_name}.war #{svn_wars_url}/#{war_name}.war -m 'commiting war #{war_name}.war'")
  end
end


if __FILE__ == $PROGRAM_NAME
  options = {}
  ARGV.each do |arg|
    key, value = arg.split("=")

    value = false if value == "false"
    key = key[2..-1].sub("-", "_").to_sym

    options[key] = value
  end

  build = CiBuild.new(ENV['SVN_URL'], ENV['WORKSPACE'], options)
  build.run
end