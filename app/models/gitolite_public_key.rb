require 'base64'

class GitolitePublicKey < ActiveRecord::Base
  unloadable

  STATUS_ACTIVE = 1
  STATUS_LOCKED = 0

  KEY_TYPE_USER = 0
  KEY_TYPE_DEPLOY = 1

  DEPLOY_PSEUDO_USER = "deploy_key"

  # These two constants are related -- don't change one without the other
  KEY_FORMATS = ['ssh-rsa', 'ssh-dss']
  KEY_NUM_COMPONENTS = [3, 5]

  belongs_to :user
  has_many   :repository_deployment_credentials, :dependent => :destroy

  scope :active,   -> { where active: STATUS_ACTIVE }
  scope :inactive, -> { where active: STATUS_LOCKED }

  scope :user_key,   -> { where key_type: KEY_TYPE_USER }
  scope :deploy_key, -> { where key_type: KEY_TYPE_DEPLOY }

  validates_presence_of   :title, :identifier, :key, :key_type
  validates_inclusion_of  :key_type, :in => [KEY_TYPE_USER, KEY_TYPE_DEPLOY]

  validates_uniqueness_of :title,      :scope => :user_id
  validates_uniqueness_of :identifier, :scope => :user_id

  validates_associated :repository_deployment_credentials

  validate :has_not_been_changed
  validate :key_format_and_uniqueness

  before_validation :set_identifier
  before_validation :strip_whitespace
  before_validation :remove_control_characters

  after_commit ->(obj) { obj.add_ssh_key },     on: :create
  after_commit ->(obj) { obj.destroy_ssh_key }, on: :destroy


  def self.by_user(user)
    where("user_id = ?", user.id)
  end


  def to_s
    title
  end


  def set_identifier
    self.identifier ||=
      begin
        my_time = Time.now
        time_tag = "#{my_time.to_i.to_s}_#{my_time.usec.to_s}"
        key_count = GitolitePublicKey.by_user(self.user).deploy_key.length + 1
        case key_type
          when KEY_TYPE_USER
            # add "redmine_" as a prefix to the username, and then the current date
            # this helps ensure uniqueness of each key identifier
            #
            # also, it ensures that it is very, very unlikely to conflict with any
            # existing key name if gitolite config is also being edited manually
            "#{self.user.gitolite_identifier}" << "@redmine_" << "#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_')
          when KEY_TYPE_DEPLOY
            # add "redmine_deploy_key_" as a prefix, and then the current date
            # to help ensure uniqueness of each key identifier
            # "redmine_#{DEPLOY_PSEUDO_USER}_#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_') << "@redmine_" << "#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_')
            "#{self.user.gitolite_identifier}_#{DEPLOY_PSEUDO_USER}_#{key_count}".gsub(/[^0-9a-zA-Z\-]/, '_') << "@redmine_" << "#{time_tag}".gsub(/[^0-9a-zA-Z\-]/, '_')
          else
            nil
          end
        end
  end


  # Make sure that current identifier is consistent with current user login.
  # This method explicitly overrides the static nature of the identifier
  def reset_identifier
    # Fix identifier
    self.identifier = nil
    set_identifier

    # Need to override the "never change identifier" constraint
    self.save(:validate => false)

    self.identifier
  end


  # Key type checking functions
  def user_key?
    key_type == KEY_TYPE_USER
  end


  def deploy_key?
    key_type == KEY_TYPE_DEPLOY
  end


  def owner
    self.identifier.split('@')[0]
  end


  def location
    self.identifier.split('@')[1]
  end


  protected


  def add_ssh_key
    RedmineGitolite::GitHosting.logger.info { "User '#{User.current.login}' has added a SSH key" }
    RedmineGitolite::GitHosting.resync_gitolite({ :command => :add_ssh_key, :object => self.user.id })
  end


  def destroy_ssh_key
    RedmineGitolite::GitHosting.logger.info { "User '#{User.current.login}' has deleted a SSH key" }

    repo_key = {}
    repo_key['title']    = self.identifier
    repo_key['key']      = self.key
    repo_key['location'] = self.location
    repo_key['owner']    = self.owner

    RedmineGitolite::GitHosting.logger.info { "Delete SSH key #{self.identifier}" }
    RedmineGitolite::GitHosting.resync_gitolite({ :command => :delete_ssh_key, :object => repo_key })
  end


  private


  # Strip leading and trailing whitespace
  def strip_whitespace
    self.title = title.strip

    # Don't mess with existing keys (since cannot change key text anyway)
    if new_record?
      self.key = key.strip
    end
  end


  # Remove control characters from key
  def remove_control_characters
    # Don't mess with existing keys (since cannot change key text anyway)
    return if !new_record?

    # First -- let the first control char or space stand (to divide key type from key)
    # Really, this is catching a special case in which there is a \n between type and key.
    # Most common case turns first space back into space....
    self.key = key.sub(/[ \r\n\t]/, ' ')

    # Next, if comment divided from key by control char, let that one stand as well
    # We can only tell this if there is an "=" in the key. So, won't help 1/3 times.
    self.key = key.sub(/=[ \r\n\t]/, '= ')

    # Delete any remaining control characters....
    self.key = key.gsub(/[\a\r\n\t]/, '').strip
  end


  def has_not_been_changed
    unless new_record?
      has_errors = false

      %w(identifier key user_id key_type).each do |attribute|
        method = "#{attribute}_changed?"
        if self.send(method)
          errors.add(attribute, 'may not be changed')
          has_errors = true
        end
      end

      return has_errors
    end
  end


  def wrap_and_join(in_array, my_or = "or")
    my_array = in_array.map{|x| "\"#{x}\""}
    length = my_array.length
    return my_array if length < 2
    my_array[length-1] = my_or + " " + my_array[length-1]
    if length == 2
      my_array.join(' ')
    else
      my_array.join(', ')
    end
  end


  def key_format_and_uniqueness
    return if key.blank?

    return if !new_record?

    # First, check that key crypto type is present and of correct form.  Also, decode base64 and see if key
    # crypto type matches.  Note that we ignore presence of comment!
    keypieces = key.match(/^(\S+)\s+(\S+)/)

    if !keypieces || keypieces[1].length > 10  # Probably has key as first component
      errors.add(:key, l(:error_key_needs_two_components))
      return false
    end

    key_format = keypieces[1]
    key_data   = keypieces[2]

    if !KEY_FORMATS.include?(key_format)
      errors.add(:key, l(:error_key_bad_type, :types => wrap_and_join(KEY_FORMATS, l(:word_or))))
      return false
    end

    # Make sure that key has proper number of characters (divisible by 4) and no more than 2 '='
    if (key_data.length % 4) != 0 || !key_data.match(/^[a-zA-Z0-9\+\/]+={0,2}$/)
      errors.add(:key, l(:error_key_corrupted))
      return false
    end

    key_data_decoded = Base64.decode64(key_data)

    piecearray = []

    while key_data_decoded.length >= 4
      length = 0
      key_data_decoded.slice!(0..3).bytes do |byte|
        length = length * 256 + byte
      end
      if key_data_decoded.length < length
        errors.add(:key, l(:error_key_corrupted))
        return false
      end
      piecearray << key_data_decoded.slice!(0..length-1)
    end

    if key_data_decoded.length != 0
      errors.add(:key, l(:error_key_corrupted))
      return false
    end

    if piecearray[0] != key_format
      errors.add(:key, l(:error_key_type_mismatch, :type1 => key_format, :type2 => piecearray[0]))
      return false
    end

    if piecearray.length != KEY_NUM_COMPONENTS[KEY_FORMATS.index(piecearray[0])]
      errors.add(:key, l(:error_key_corrupted))
      return false
    end

    # First version of uniqueness check -- simply check all keys...

    # Check against the gitolite administrator key file (owned by noone).
    all_keys = []

    all_keys.push GitolitePublicKey.new({ :user => nil, :key => File.read(RedmineGitolite::ConfigRedmine.get_setting(:gitolite_ssh_public_key)) })

    # Check all active keys
    all_keys += (GitolitePublicKey.active.all)

    all_keys.each do |existing_key|

      existingpieces = existing_key.key.match(/^(\S+)\s+(\S+)/)

      if existingpieces && (existingpieces[2] == key_data)
        # Hm.... have a duplicate key!
        if existing_key.user == User.current
          errors.add(:key, l(:error_key_in_use_by_you, :name => existing_key.title))
          return false
        elsif User.current.admin?
          if existing_key.user
            errors.add(:key, l(:error_key_in_use_by_other, :login => existing_key.user.login, :name => existing_key.title))
            return false
          else
            errors.add(:key, l(:error_key_in_use_by_gitolite_admin))
            return false
          end
        else
          errors.add(:key, l(:error_key_in_use_by_someone))
          return false
        end
      end
    end

  end

end
