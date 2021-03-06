class GitolitePublicKeysController < ApplicationController
  unloadable

  before_filter :require_login
  before_filter :set_user_variable
  before_filter :set_users_keys, :except => [:index, :new, :reset_rss_key]
  before_filter :find_gitolite_public_key, :except => [:index, :new, :reset_rss_key, :create]

  helper :issues
  helper :users
  helper :custom_fields

  helper :gitolite_public_keys


  def create
    @gitolite_public_key = GitolitePublicKey.new(params[:gitolite_public_key].merge(:user => @user))

    if params[:create_button]
      if @gitolite_public_key.save
        flash[:notice] = l(:notice_public_key_created, :title => view_context.keylabel(@gitolite_public_key))

        respond_to do |format|
          format.html { redirect_to @redirect_url }
        end
      else
        flash[:error] = @gitolite_public_key.errors.full_messages.to_sentence

        respond_to do |format|
          format.html { redirect_to @redirect_url }
        end
      end
    else
      respond_to do |format|
        format.html { redirect_to @redirect_url }
      end
    end
  end


  def edit
    redirect_to url_for(:controller => 'my', :action => 'account', :public_key_id => @gitolite_public_key[:id])
  end


  def update
    if !request.get?
      if params[:save_button]
        if @gitolite_public_key.update_attributes(params[:gitolite_public_key])
          flash[:notice] = l(:notice_public_key_updated, :title => view_context.keylabel(@gitolite_public_key))

          respond_to do |format|
            format.html { redirect_to @redirect_url }
          end
        else
          flash[:error] = @gitolite_public_key.errors.full_messages.to_sentence

          respond_to do |format|
            format.html { redirect_to @redirect_url }
          end
        end
      else
        destroy_key if params[:delete_button]

        respond_to do |format|
          format.html { redirect_to @redirect_url }
        end
      end
    end
  end


  def destroy
    if request.delete?
      if @gitolite_public_key.destroy
        flash[:notice] = l(:notice_public_key_deleted, :title => view_context.keylabel(@gitolite_public_key))
      end
      redirect_to @redirect_url
    end
  end


  protected


  def set_user_variable
    if params[:user_id]
      @user = (params[:user_id] == 'current') ? User.current : User.find_by_id(params[:user_id])
      if @user
        @redirect_url = url_for(:controller => 'users', :action => 'edit', :id => params[:user_id], :tab => 'keys')
      else
        render_404
      end
    else
      @user = User.current
      @redirect_url = url_for(:controller => 'my', :action => 'account')
    end
  end


  def set_users_keys
    @gitolite_user_keys   = @user.gitolite_public_keys.user_key.active.order('title ASC, created_at ASC')
    @gitolite_deploy_keys = @user.gitolite_public_keys.deploy_key.active.order('title ASC, created_at ASC')
    @gitolite_public_keys = @gitolite_user_keys + @gitolite_deploy_keys
  end


  def find_gitolite_public_key
    key = GitolitePublicKey.find_by_id(params[:id])
    if key && (@user == key.user || @user.admin?)
      @gitolite_public_key = key
    elsif key
      render_403
    else
      render_404
    end
  end


  # Suggest title for new one-of deployment key
  def suggested_title
    # Base of suggested title
    default_title = "#{@project.name} Deploy Key"

    # Find number of keys or max default deploy key that matches
    maxnum = @repository.repository_deployment_credentials.map(&:gitolite_public_key).uniq.count
    @repository.repository_deployment_credentials.each do |credential|
      if matches = credential.gitolite_public_key.title.match(/#{default_title} (\d+)$/)
        maxnum = [maxnum, matches[1].to_i].max
      end
    end

    # Also, check for uniqueness for current user
    @user.gitolite_public_keys.each do |key|
      if matches = key.title.match(/#{default_title} (\d+)$/)
        maxnum = [maxnum, matches[1].to_i].max
      end
    end

    return "#{default_title} #{maxnum + 1}"
  end

end
