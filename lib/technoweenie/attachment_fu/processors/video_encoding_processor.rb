
module Technoweenie::AttachmentFu::Processors::VideoEncodingProcessor
  VIDEOS = [
    'video/3gpp',
    'video/3gpp2',
    'video/mp4',
    'video/mpeg',
    'video/MJ2',
    'video/ogg',
    'video/quicktime',
    'video/vnd.objectvideo',
    'video/x-flv',
    'application/vnd.ms-asf',
    'video/x-ms-asf',
    'video/x-ms-wmv',
    'video/x-msvideo' ]

  def self.included(base)
    base.send :extend, ClassMethods

    base.send :include, AASM

    base.aasm_column :encoding_status
    base.aasm_initial_state :encoding_init

    base.aasm_state :encoding_init     # initial state
    base.aasm_state :encoding_started  # video is being processed
    base.aasm_state :encoding_done     # done, we have encoded video
    base.aasm_state :encoding_error    # error while processing

    base.aasm_event :submitted_for_encoding do
      transitions :from => [:encoding_init, :encoding_done, :encoding_error], :to => :encoding_started
    end

    base.aasm_event :encoding_done do
      transitions :from => :encoding_started, :to => :encoding_done
    end

    base.aasm_event :encoding_error do
      transitions :from => [:encoding_init, :encoding_started], :to => :encoding_error
    end

    base.after_attachment_saved do |attachment|
      attachment.trigger_encoding
    end
  end

  module ClassMethods
    def process_encoder_callback(xml_string)
      msg = REXML::Document.new(xml_string)

      media_id_node = msg.root.elements["mediaid"]
      raise "Did not receive a media ID with the callback." if media_id_node.nil?

      att = find_by_external_encoding_id(media_id_node.text)
      if att.nil?
        logger.warn("Don't know about media ID '#{media_id_node.text}' received by encoding.com:\n#{xml_string}")
      else
        att.process_encoder_callback(msg)
      end
    end
  end

  def image?(thumbnail = nil)
    return false if thumbnail.blank?
    attachment_options[:thumbnails].key?(thumbnail)
  end

  def video?(thumbnail = nil)
    return true if thumbnail.blank?
    attachment_options[:videos].include?(thumbnail)
  end

  def thumbnail_name_for(thumbnail = nil)
    return filename if thumbnail.blank?
    base_name = filename.sub(/\.\w+$/, '')
    if video?(thumbnail)
      "#{base_name}_#{thumbnail}.mp4"
    else
      "#{base_name}_#{thumbnail}.jpg"
    end
  end

  def trigger_encoding
    return unless parent_id.nil?
    begin
      self.external_encoding_id = nil
      submitted_for_encoding
      request_xml = encoding_request_xml
      logger.info("Request to encoding.com:\n#{request_xml}")
      response = Net::HTTP.post_form(URI.parse('http://manage.encoding.com/'), { 'xml' => request_xml })
      logger.info("Response from encoding.com:\n#{response.body}")
      msg = REXML::Document.new(response.body)
      if msg.root.nil?
        logger.warn("Invalid response from encoding.com. Response was:\n#{response.body}")
      else
        media_id_node = msg.root.elements["MediaID"]
        if media_id_node.nil?
          logger.warn("Did not receive a media ID from encoding.com. Response was:\n#{response.body}")
        else
          logger.info("Got media ID '#{media_id_node.text}'.")
          self.external_encoding_id = media_id_node.text
        end
      end
    rescue Exception => err
      logger.warn("Exception while triggering encoding: #{err}")
    ensure
      encoding_error unless self.external_encoding_id
      save!
    end
  end

  def process_encoder_callback(msg)
    status_node = msg.root.elements["status"]
    raise "Did not receive a status with the callback." if status_node.nil?

    unless status_node.text == "Finished"
      logger.warn("Status '#{status_node.text}' indicates an error by encoding.com:\n#{msg}")
      encoding_error
      save!
      return
    end

    attachment_options[:videos].each do |suffix, options|
      thumb = find_or_initialize_alternative_format(suffix)
      thumb.send(:'attributes=', {
        :content_type => "video/mp4",
        :size         => "1", # TODO
        :filename     => thumbnail_name_for(suffix)}, false)
      thumb.save!
    end

    attachment_options[:thumbnails].each do |suffix, size|
      thumb = find_or_initialize_thumbnail(suffix)
      thumb.send(:'attributes=', {
        :content_type => "image/jpeg",
        :width        => size[0],
        :height       => size[1],
        :size         => "1", # TODO
        :filename     => thumbnail_name_for(suffix)}, false)
      thumb.save!
    end

    encoding_done
    save!
  end

  protected

  # Initializes a new alternative format with the given suffix.
  def find_or_initialize_alternative_format(suffix)
    self.class.find_or_initialize_by_thumbnail_and_parent_id(suffix.to_s, id)
  end

  def encoding_request_xml
    builder = Builder::XmlMarkup.new
    builder.query do |b|
      b.userid(AppConfig.encoding_com.user_id)
      b.userkey(AppConfig.encoding_com.user_key)
      b.action("AddMedia")
      b.source(public_filename)
      b.notify(attachment_options[:encoding_callback_url])

      attachment_options[:videos].each do |suffix, options|
        b.format do |f|
          f.output(options[:output] || suffix.to_s)
          f.video_codec(options[:video_codec]) if options[:video_codec]
          f.two_pass(options[:two_pass] ? "yes" : "no")
          f.destination("http://#{bucket_name}.s3.amazonaws.com/#{full_filename(suffix)}?acl=public-read")
        end
      end

      attachment_options[:thumbnails].each do |suffix, size|
        b.format do |f|
          f.output("thumbnail")
          f.width(size[0])
          f.height(size[1])
          f.destination("http://#{bucket_name}.s3.amazonaws.com/#{full_filename(suffix)}?acl=public-read")
        end
      end
    end
  end

end
