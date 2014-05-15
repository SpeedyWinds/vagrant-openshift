#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++
require "tempfile"
require "timeout"

module Vagrant
  module Openshift
    module CommandHelper
      def scl_wrapper(is_fedora, command)
        is_fedora ? command : %{scl enable ruby193 "#{command}"}
      end

      def sudo(machine, command, options={})
        stdout = []
        stderr = []
        rc = -1
        options[:timeout] = 60*10 unless options.has_key? :timeout
        options[:retries] = 1 unless options.has_key? :retries
        options[:fail_on_error] = true unless options.has_key? :fail_on_error

        (1..options[:retries]).each do |retry_count|
          begin
            machine.env.ui.info "Running ssh/sudo command '#{command}' with timeout #{options[:timeout]}. Attempt ##{retry_count}"
            Timeout::timeout(options[:timeout]) do
              rc = machine.communicate.sudo(command) do |type, data|
                if [:stderr, :stdout].include?(type)
                  if type == :stdout
                    color = :green
                    stdout << data
                  else
                    color = :red
                    stderr << data
                  end
                  machine.env.ui.info(data, :color => color, :new_line => false, :prefix => false) unless options[:buffered_output] == true
                end
              end
            end
          rescue Timeout::Error
            machine.env.ui.warn "Timeout occurred while running ssh/sudo command: #{command}"
            rc = -1
          rescue Exception => e
            machine.env.ui.warn "Error while running ssh/sudo command: #{command}"
            rc ||= -1
          end

          break if rc == 0
        end
        exit rc if options[:fail_on_error] && rc != 0

        [stdout, stderr, rc]
      end

      def do_execute(machine, command)
        stdout = []
        stderr = []
        rc = -1

        machine.env.ui.info "Running command '#{command}'"
        rc = machine.communicate.execute(command) do |type, data|
          if [:stderr, :stdout].include?(type)
            if type == :stdout
              color = :green
              stdout << data
            else
              color = :red
              stderr << data
            end
            machine.env.ui.info(data, :color => color, :new_line => false, :prefix => false)
          end
        end

        [stdout, stderr, rc]
      end

      def remote_write(machine, dest, owner="root", perms="0644", &block)
        file = Tempfile.new('file')
        begin
          file.write(block.yield)
          file.flush
          file.close
          machine.communicate.upload(file.path, "/tmp/#{File.basename(file)}")
          dest_dir = File.dirname(dest)
          sudo(machine,
%{mkdir -p #{dest_dir};
mv /tmp/#{File.basename(file)} #{dest} &&
chown #{owner} #{dest} &&
chmod #{perms} #{dest}})
        ensure
          file.unlink
        end
      end

      def sync_bash_command(repo_name, build_cmd, refname="master", sync_path="/data/.sync", commit_id_path="#{sync_path}/#{repo_name}")
        cmd = %{
pushd /data/src/github.com/openshift/#{repo_name}
  commit_id=`git rev-parse #{refname}`
  if [ -f #{commit_id_path} ]
  then
    previous_commit_id=$(cat #{commit_id_path})
  fi
  if [ "$previous_commit_id" != "$commit_id" ]
  then
    #{build_cmd}
  else
    echo "No update for #{repo_name}, #{refname}"
  fi
  mkdir -p #{sync_path}
  echo -n $commit_id > #{commit_id_path}
popd         
        }

      end

      def sync_bash_command_on_dockerfile(repo_name, dockerfile_build_path, build_cmd)              
        refname = "master:#{dockerfile_build_path}/Dockerfile"
        sync_path = "/data/.sync/dockerfile/#{repo_name}/#{dockerfile_build_path}"
        commit_id_path = "#{sync_path}/Dockerfile"
        sync_bash_command(repo_name, build_cmd, refname, sync_path, commit_id_path)
      end

      def repo_checkout(repo, url)
        repo_path = File.expand_path(repo)
        if Pathname.new(repo_path).exist?
          if @options[:replace]
            puts "Replacing: #{repo_path}"
            system("rm -rf #{repo_path}")
          else
            puts "Already cloned: #{repo}"
            next
          end
        end
        cloned = false
        if @options[:user]
          if system("git clone git@github.com:#{@options[:user]}/#{repo}")
            cloned = true
            Dir.chdir(repo) do
              system("git remote add upstream #{url} && git fetch upstream")
            end
          else
            @env.ui.warn "Fork of repo #{repo} not found. Cloning read-only copy from upstream"
          end
        end
        if not cloned
          system("git clone #{url}")
        end
        Dir.chdir(repo) do
          system("git checkout #{@options[:branch]}")
        end

      end

    end
  end
end
