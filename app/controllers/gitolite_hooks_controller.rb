class GitoliteHooksController < ApplicationController

	skip_before_filter :verify_authenticity_token, :check_if_login_required, :except => :test
	before_filter  :find_project

	helper :git_hosting
	include GitHostingHelper


	def stub
		# Stub method simply to generate correct urls, just return a 404 to any user requesting this
		render(:code => 404)
	end

	def post_receive

		if not @project.repository.extra.validate_encoded_time(params[:clear_time], params[:encoded_time])
			render(:text => "The hook key provided is not valid. Please let your server admin know about it")
			return
		end

		# Clear existing cache
		GitHosting::clear_cache_for_project(@project)

		repo_path = GitHosting.repository_path(@project)

		render :text => Proc.new { |response, output|
			response.headers["Content-Type"] = "text/plain;"

			# Fetch commits from the repository
			GitHosting.logger.debug "Fetching changesets for #{@project.name}'s repository"
			output.write("Fetching changesets for #{@project.name}'s repository ... ")
			output.flush
			Repository.fetch_changesets_for_project(@project.identifier)
			output.write("Done\n")
			output.flush

			@project.repository_mirrors.all(:order => 'active DESC, created_at ASC', :conditions => "active=1").each {|mirror|
				GitHosting.logger.debug "Pushing changes to mirror #{mirror.url}"
				output.write("Pushing changes to mirror #{mirror.url} ... ")
				output.flush
				
				mirror_err = mirror.push
				
				result = mirror_err.length > 0 ? "Failed!\n" + mirror_err : "Done\n"
				output.write(result)
				output.flush
			} if @project.repository_mirrors.any?

			# Notify CIA
			#Thread.abort_on_exception = true
			Thread.new(@project, params[:refs]) {|project, refs|
				GitHosting.logger.debug "Notifying CIA"
				output.write("Notifying CIA\n")
				output.flush
				#GitHosting.logger.debug "REFS #{refs}"

				refs.each {|ref|
					oldhead, newhead, refname = ref.split(',')

					# Only pay attention to branch updates
					next if not refname.match(/refs\/heads\//)

					branch = refname.gsub('refs/heads/', '')

					if newhead.match(/^0{40}$/)
						# Deleting a branch
						GitHosting.logger.debug "Deleting branch \"#{branch}\""
						next
					elsif oldhead.match(/^0{40}$/)
						# Creating a branch
						GitHosting.logger.debug "Creating branch \"#{branch}\""
						range = newhead
					else
						range = "#{oldhead}..#{newhead}"
					end

					revisions = %x[#{GitHosting.git_exec} --git-dir='#{GitHosting.repository_path(@project)}' rev-list --reverse #{range}]
					#GitHosting.logger.debug "Revisions in Range: #{revisions.split().join(' ')}"

					revisions.split().each{|rev|
						revision = project.repository.find_changeset_by_name(rev.strip)
						#GitHosting.logger.debug "Revision Found: #{revision.revision}"
						next if project.repository.cia_notifications.notified?(revision)  # Already notified about this commit
						GitHosting.logger.info "Notifying CIA: Branch => #{branch} REVISION => #{revision.revision}"
						CiaNotificationMailer.deliver_notification(revision, branch)
						project.repository.cia_notifications.notified(revision)
					}
				}
			} if !params[:refs].nil? && @project.repository.extra.notify_cia==1
		}, :layout => false
	end

	def test
		# Deny access if the curreent user is not allowed to manage the project's repositoy
		not_enough_perms = true
		User.current.roles_for_project(@project).each{|role|
			if role.allowed_to? :manage_repository
				not_enough_perms = false
				break
			end
		}
		return render(:text => l(:cia_not_enough_permissions), :status => 403) if not_enough_perms

		# Grab the repository path
		repo_path = GitHosting.repository_path(@project)
		# Get the last revision we have on the database for this project
		revision = @project.repository.changesets.find(:first)
		# Find out to which branch this commit belongs to
		branch = %x[#{GitHosting.git_exec} --git-dir='#{repo_path}' branch --contains  #{revision.scmid}].split('\n')[0].strip.gsub(/\* /, '')
		GitHosting.logger.debug "Revision #{revision.scmid} found on branch #{branch}"

		# Send the test notification
		GitHosting.logger.info "Sending Test Notification to CIA: Branch => #{branch} RANGE => #{revision.revision}"
		CiaNotificationMailer.deliver_notification(revision, branch)
		render(:text => l(:cia_notification_ok))
	end

	def find_project
		@project = Project.find_by_identifier(params[:projectid])
		if @project.nil?
			render(:text => l(:project_not_found, :identifier => params[:projectid])) if @project.nil?
			return
		end
	end

end
