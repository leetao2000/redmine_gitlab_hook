require 'json'

class GitlabHookController < SysController
  GIT_BIN = Redmine::Configuration[:scm_git_command] || 'git'

  def index
    if request.post?
      begin
        project_ids = get_project_identifiers
        results = project_ids.map do |project_id|
          begin
            repository = find_repository(project_id)
            git_success = true

            if repository
              # Fetch the changes from GitLab
              if Setting.plugin_redmine_gitlab_hook['fetch_updates'] == 'yes'
                git_success = update_repository(repository)
              end
              if git_success
                # Fetch the new changesets into Redmine
                repository.fetch_changesets
                { project_id: project_id, status: 'success', message: 'OK' }
              else
                { project_id: project_id, status: 'failure', message: "Git command failed on repository: #{repository.identifier}!" }
              end
            else
              { project_id: project_id, status: 'failure', message: "Repository not found for project_id: #{project_id}" }
            end
          rescue => e
            logger.error "Error processing project_id #{project_id}: #{e.message}"
            { project_id: project_id, status: 'failure', message: e.message }
          end
        end

        if results.any? { |result| result[:status] == 'success' }
          render(plain: results.to_json, status: :ok)
        else
          render(plain: results.to_json, status: :not_acceptable)
        end
      rescue => e
        logger.error "Error in index: #{e.message}"
        render(plain: "Unexpected error: #{e.message}", status: :internal_server_error)
      end
    else
      raise ActionController::RoutingError.new('Not Found')
    end
  end

  private

  def system(command)
    Kernel.system(command)
  end

  def exec(command)
    logger.debug { "GitLabHook: Executing command: '#{command}'" }

    logfile = Tempfile.new('gitlab_hook_exec')
    logfile.close

    success = system("#{command} > #{logfile.path} 2>&1")
    output_from_command = File.readlines(logfile.path)
    if success
      logger.debug { "GitLabHook: Command output: #{output_from_command.inspect}" }
    else
      logger.error { "GitLabHook: Command '#{command}' failed. Output: #{output_from_command.inspect}" }
    end

    success
  ensure
    logfile.unlink
  end

  def git_command(prefix, command, repository)
    "#{prefix} #{GIT_BIN} --git-dir=\"#{repository.url}\" #{command}"
  end

  def update_repository(repository)
    prune = Setting.plugin_redmine_gitlab_hook['prune'] == 'yes' ? ' -p' : ''
    prefix = Setting.plugin_redmine_gitlab_hook['git_command_prefix'].to_s

    if Setting.plugin_redmine_gitlab_hook['all_branches'] == 'yes'
      command = git_command(prefix, "fetch --all#{prune}", repository)
      exec(command)
    else
      command = git_command(prefix, "fetch#{prune} origin", repository)
      if exec(command)
        command = git_command(prefix, "fetch#{prune} origin '+refs/heads/*:refs/heads/*'", repository)
        exec(command)
      end
    end
  end

  def get_project_identifiers
    raise ArgumentError, 'project_id parameter is missing or invalid' if params[:project_id].blank?

    params[:project_id].to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def find_repository(project_id)
    repo_namespace = get_repository_namespace
    repo_name = get_repository_name || project_id
    repository_id = repo_namespace.present? ? "#{repo_namespace}_#{repo_name}" : repo_name

    project = find_project(project_id)
    repository = project.repositories.find_by_identifier_param(repository_id)

    if repository.nil?
      if Setting.plugin_redmine_gitlab_hook['auto_create'] == 'yes'
        repository = create_repository(project, repo_namespace, repo_name)
      else
        raise TypeError, "Project '#{project.identifier}' has no repository or repository not found with identifier '#{repository_id}'"
      end
    elsif !repository.is_a?(Repository::Git)
      raise TypeError, "'#{repository_id}' is not a Git repository"
    end

    repository
  end

  def find_project(project_id)
    project = Project.find_by_identifier(project_id.downcase)
    raise ActiveRecord::RecordNotFound, "No project found with identifier '#{project_id}'" if project.nil?

    project
  end

  def get_repository_namespace
    params[:repository_namespace]&.downcase
  end

  def get_repository_name
    params[:repository_name]&.downcase
  end

  def create_repository(project, repo_namespace, repo_name)
    logger.debug('Trying to create repository...')
    local_root_path = Setting.plugin_redmine_gitlab_hook['local_repositories_path'].to_s
    raise TypeError, 'Local repository path is not set' if local_root_path.blank?

    remote_url = params[:repository_git_url]
    prefix = Setting.plugin_redmine_gitlab_hook['git_command_prefix'].to_s
    raise TypeError, 'Remote repository URL is null' unless remote_url.present?

    local_url = File.join(local_root_path, repo_namespace || '', repo_name)
    git_file = File.join(local_url, 'HEAD')

    unless File.exist?(git_file)
      FileUtils.mkdir_p(local_url)
      command = "#{prefix} #{GIT_BIN} clone --mirror #{remote_url} #{local_url}"
      raise RuntimeError, "Can't clone URL #{remote_url}" unless exec(command)
    end

    repository = Repository::Git.new
    repository.identifier = "#{repo_namespace}_#{repo_name}" if repo_namespace
    repository.url = local_url
    repository.is_default = true
    repository.project = project
    repository.save
    repository
  end
  
end
