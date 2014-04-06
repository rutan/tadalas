# coding: utf-8

require 'sinatra/base'
require 'sinatra/rocketio'
require 'sinatra/content_for'

require 'figaro'

require 'slim'
require 'sass'
require 'coffee-script'

require 'azure'

require 'RMagick'

# Sinatra Setting
class Tadalas < Sinatra::Base
  register Sinatra::RocketIO
  helpers Sinatra::ContentFor

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end
end

# Figaro Setting
# https://github.com/laserlemon/figaro/issues/60
module Figaro
  def path
    @path ||= File.join(Tadalas.settings.root, 'config', 'application.yml')
  end

  def environment
    Tadalas.settings.environment
  end
end
Figaro.env.each { |key, value| ENV[key] = value unless ENV.key?(key) }

# AzureSetting
Azure.configure do |config|
  config.storage_account_name = Figaro.env.account_name
  config.storage_access_key = Figaro.env.access_key
end

# Azure File Access
class AzureFile
  def initialize(container_name, filename)
    @service = Azure::BlobService.new
    @container_name = container_name
    @filename = filename
  end

  def read
    unless @data
      blob, @data = @service.get_blob(@container_name, @filename)
    end
    @data
  end

  def store!(file)
    file.pos = 0
    @service.create_block_blob(@container_name, @filename, file.read)
    @data = nil
  end
end

# Sinatra
class Tadalas < Sinatra::Base
  use Rack::Session::Cookie,
      key: '_session',
      expire_after: 60 * 60 * 24,
      secret: Figaro.env.secret
  use Rack::Protection

  io = Sinatra::RocketIO
  LAST_IMAGE_PATH = './tmp/picture.png'
  IMAGE_SIZE = 480

  get '/' do
    slim :index
  end

  post '/picture' do
    if params[:file]
      image = Magick::Image.read(params[:file][:tempfile].path).first
      w = image.columns
      h = image.rows
      image.format = 'png'
      image.resize_to_fit!([IMAGE_SIZE, w].min, [IMAGE_SIZE, h].min)
      image.write(LAST_IMAGE_PATH)

      azure_file = AzureFile.new(Figaro.env.container, Figaro.env.filename)
      azure_file.store!(File.open(LAST_IMAGE_PATH))

      io.push 'reload', Time.now.to_i
    end
    redirect '/'
  end

  get '/picture' do
    content_type 'image/png'
    if File.exists?(LAST_IMAGE_PATH)
      File.open(LAST_IMAGE_PATH, 'rb') { |f| f.read }
    else
      azure_file = AzureFile.new(Figaro.env.container, Figaro.env.filename)
      File.open(LAST_IMAGE_PATH, 'wb') { |f| f.write azure_file.read }
      azure_file.read
    end
  end
end
