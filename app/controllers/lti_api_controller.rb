#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require 'oauth/request_proxy/action_controller_request'

class LtiApiController < ApplicationController

  class Unauthorized < Exception; end

  def grade_passback
    require_context

    # load the external tool to grab the key and secret
    @assignment = @context.assignments.find(params[:assignment_id])
    @user = @context.students.find(params[:id])
    tag = @assignment.external_tool_tag
    @tool = ContextExternalTool.find_external_tool(tag.url, @context) if tag

    raise(Unauthorized, "LTI tool not found") unless @tool

    # verify the request oauth signature
    begin
      @signature = OAuth::Signature.build(request, :consumer_secret => @tool.shared_secret)
      @signature.verify() or raise OAuth::Unauthorized
    rescue OAuth::Signature::UnknownSignatureMethod,
           OAuth::Unauthorized
      raise Unauthorized, "Invalid authorization header"
    end

    timestamp = Time.zone.at(@signature.request.timestamp.to_i)
    # 90 minutes is suggested by the LTI spec
    allowed_delta = Setting.get_cached('oauth.allowed_timestamp_delta', 90.minutes.to_s).to_i
    if timestamp < allowed_delta.ago || timestamp > allowed_delta.from_now
      raise Unauthorized, "Timestamp too old, request has expired"
    end

    nonce = @signature.request.nonce
    unless Canvas::Redis.lock("nonce:#{@tool.asset_string}:#{nonce}", allowed_delta)
      raise Unauthorized, "Duplicate nonce detected"
    end

    if request.content_type != "application/xml"
      return render :text => '', :status => 415
    end

    xml = Nokogiri::XML.parse(request.body)

    lti_response = BasicLTI::BasicOutcomes.process_request(@tool, @context, @assignment, @user, xml)
    render :text => lti_response.to_xml, :content_type => 'application/xml'

  rescue Unauthorized => e
    render :text => e.to_s, :content_type => 'application/xml', :status => 401
  end
end