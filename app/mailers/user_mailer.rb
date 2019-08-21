class UserMailer < SchoolMailer
  # Mails sent directly to students.
  class FounderMailer < SchoolMailer
    # Mail sent a little while after the a confirmed connect request meeting occured.
    #
    # @param connect_request [ConnectRequest] Request for a meeting which recently occurred.
    def connect_request_feedback(connect_request)
      @connect_request = connect_request
      @faculty = connect_request.faculty
      # TODO: Do we need to send this to each founder?
      @founder = connect_request.startup.founders.first
      @school = @founder.school

      simple_roadie_mail(@founder.email, "Feedback for your recent office hour with coach #{@faculty.name}")
    end
  end

  # Mail sent to community user when a new answer is posted to one of their questions.
  #
  # @param answer [Answer] The newly posted answer.
  def new_answer(answer)
    @answer = answer
    @school = @answer.school
    simple_roadie_mail(answer.question.creator.email, 'New answer for your question')
  end

  # Mail sent to community user when a new comments is posted to one of their questions / answers.
  #
  # @param comment [Comment] The newly posted comment.
  def new_comment(comment)
    @comment = comment
    @school = @comment.commentable.school
    simple_roadie_mail(comment.commentable.creator.email, 'New comment on your post')
  end

  # Mail sent daily to users when there are new questions posted in communities where they have access.
  #
  # @param user [User] user to whom digest is to be sent
  # @param updates [Hash] digest details
  def daily_digest(user, updates)
    @user = user
    @updates = updates
    @school = user.school
    subject = "#{user.school.name}: Daily Digest - #{Time.zone.now.strftime('%b %-d, %Y')}"
    simple_roadie_mail(user.email, subject)
  end
end
