require 'sinatra'
require 'sinatra/config_file'
require 'mongo'
require 'mongo_mapper'
require 'pry'
require 'json/ext'
require 'aws/s3'

class Setting
  include MongoMapper::Document
  
  key :installation_id, Integer
end

class Survey
  include MongoMapper::Document

  key :title, String
  key :code, Integer
  key :status, String
  key :start_date, Time
  key :inputs, Array

end

class Response
  include MongoMapper::Document

  key :survey_id, Integer
  key :answers, Array
end

class PTApi < Sinatra::Base
  register Sinatra::ConfigFile

  config_file File.dirname(__FILE__) + '/../config.yml'

  configure do
    set :public_folder, File.dirname(__FILE__) + '/../public/'
    enable :static, :logging

    MongoMapper.connection = Mongo::Connection.new('localhost', 27017)
    MongoMapper.database = 'pt-api'
  end

  before do
    headers 'Access-Control-Allow-Origin' => '*'
    content_type 'application/json'

    if request.post?
      error 401 unless env['HTTP_AUTHORIZATION'] == settings.access_key
    end
  end

  options '*' do
    response.headers['Allow'] = 'HEAD,GET,POST,PUT,DELETE,OPTIONS'
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'X-Requested-With, X-HTTP-Method-Override, Content-Type, Authorization, Accept, Cache-Control'
    200
  end

  get '/getId' do
    setting = Setting.first()
    id = setting.installation_id

    id += 1
    setting.installation_id = id
    if setting.save
      {
        status: 'success',
        payload: {installation_id: id}
      }.to_json
    end
  end

  get '/surveys' do
    surveys = Survey.all

    {
      status: 'success',
      payload: surveys
    }.to_json
  end

  post '/surveys/:status' do
    data = JSON.parse(request.body.read)
    survey = Survey.first(id: data['id'])

    if survey
      survey.set(data)
    else
      survey = Survey.create(data)
    end

    survey.reload
    survey.status = params[:status]
    survey.start_date = Time.now.midnight
    Response.destroy_all({survey_id: survey.id})

    if survey.save
      {
        status: 'success',
        payload: { id: survey.id, start_date: survey.start_date }
      }.to_json
    else
      {
        status: 'error',
        error_code: 13,
        error_message: 'Survey could not be saved because id is already taken'
      }.to_json
    end
  end

  get '/surveys/:code' do
    survey = Survey.first(code: params[:code].to_i)

    if survey
      {
        status: 'success',
        payload: survey
      }.to_json
    else
      {
        status: 'error',
        error_code: 12,
        error_message: 'Survey not found'
      }.to_json
    end
  end

  put '/surveys/:code/close' do
    survey = Survey.first(code: params[:code].to_i)
    
    if survey
      survey.status = 'closed'
      survey.save
      { 
        status: 'success',
        payload: { id: survey.id }
      }.to_json
    else 
      {
        status: 'error',
        error_code: 12,
        error_message: 'Survey not found'
      }.to_json
    end
  end

  get '/surveys/:code/responses' do
    survey = Survey.first(code: params[:code].to_i)

    if survey
      {
        status: 'success',
        payload: Response.where(survey_id: survey.id).sort(:timestamp.desc)
      }.to_json
    else
      {
        status: 'error',
        error_code: 12,
        error_message: 'Survey not found'
      }.to_json
    end
  end

  get '/surveys/:code/survey-with-responses' do
    survey = Survey.first(code: params[:code].to_i)

    if survey
      {
        status: 'success',
        payload: {
          survey: survey,
          responses: Response.where(survey_id: survey.id).sort(:timestamp.desc)
        }
      }.to_json
    else
      {
        status: 'error',
        error_code: 12,
        error_message: 'Survey not found'
      }.to_json
    end
  end

  get '/responses' do
    {
      status: 'success',
      payload: Response.all
    }.to_json
  end

  post '/responses' do
    response_data = JSON.parse(params[:response])
    survey = Survey.first(_id: response_data['survey_id'].to_i)
    duplicate = Response.first(
      installation_id: response_data['installation_id'],
      timestamp: response_data['timestamp']
    )

    if survey && !duplicate
      if survey.status != 'closed'
        response = Response.create(response_data)
        {
          status: 'success',
          payload: {id: response.id}
        }.to_json
      else
        {
          status: 'error',
          error_code: 14,
          error_message: 'Response could not be posted because survey is closed'
        }.to_json
      end
    elsif duplicate
      {
        status: 'success',
        payload: {id: duplicate.id}
      }.to_json
    else
      {
        status: 'error',
        error_code: 12,
        error_message: 'Survey not found'
      }.to_json
    end
  end

  post '/upload_image' do
    original_name = params[:file][:filename]
    filename = SecureRandom.urlsafe_base64
    filename = filename + original_name[original_name.rindex('.')..-1]
    file = params[:file][:tempfile]

    # rescue errors from S3
    begin
      AWS::S3::Base.establish_connection!(
        access_key_id: settings.aws_access_key_id,
        secret_access_key: settings.aws_secret_access_key
      )

      AWS::S3::S3Object.store(
        filename,
        open(file),
        settings.aws_bucket,
        access: :public_read
      )

      response = Response.find(params[:id])

      if response
        input = response[:answers].select {|input| input['id'] == params[:input_id].to_i}
        if input
          answer = input[0]['value']
          binding.pry
          url = "https://#{settings.aws_bucket}.s3.amazonaws.com/#{filename}"
          answer.kind_of?(Array) ? answer[answer.index(params[:file_location])] = url : answer = url

          if response.save
            {
              status: 'success',
              payload: {id: params[:id], input_id: params[:input_id]}
            }.to_json
          else
            {
              status: 'error',
              error_code: 16,
              error_message: 'File Upload: cannot update response object'
            }.to_json
          end
        else
          {
            status: 'error',
            error_code: 15,
            error_message: 'File Upload: cannot find the corresponding input'
          }.to_json
        end
      else
        {
          status: 'error',
          error_code: 14,
          error_message: 'File Upload: cannot find the reskponse'
        }.to_json
      end
    rescue AWS::S3::Error
      return {
        status: 'error',
        error_code: 17,
        error_message: 'File save failed'
      }.to_json
    end
  end # end post to S3
end