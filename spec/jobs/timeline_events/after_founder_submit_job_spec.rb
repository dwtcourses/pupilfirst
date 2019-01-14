require 'rails_helper'

describe TimelineEvents::AfterFounderSubmitJob do
  subject { described_class }

  let(:faculty) { create :faculty }
  let(:inactive_faculty) { create :faculty, inactive: true }
  let(:startup) { create :startup, :subscription_active }
  let(:timeline_event) { create :timeline_event, founders: startup.founders }
  let(:mock_service) { instance_double(TimelineEvents::MarkAsImprovedTargetService, execute: nil) }

  describe '#perform' do
    before do
      allow(TimelineEvents::MarkAsImprovedTargetService).to receive(:new).and_return(mock_service)
    end

    it 'executes the MarkAsImprovedTargetService' do
      expect(mock_service).to receive(:execute)
      subject.perform_now(timeline_event)
    end

    context 'when the startup has a coach' do
      before do
        create :faculty_startup_enrollment, startup: startup, faculty: faculty
        create :faculty_startup_enrollment, startup: startup, faculty: inactive_faculty
      end

      it 'sends a notification email to the coach' do
        subject.perform_now(timeline_event)

        # It should not sent any emails to inactive faculty.
        open_email(inactive_faculty.email)

        expect(current_email).to be_nil

        # It should send an email to active faculty.
        open_email(faculty.email)

        expect(current_email.subject).to eq("There is a new submission from #{startup.product_name}")
        expect(current_email.body).to include('New Submission from Student')
        expect(current_email.body).to include("We have received a new submission from #{startup.team_lead.name}")
      end
    end

    context 'when the startup does not have a coach' do
      it 'does not send any emails' do
        subject.perform_now(timeline_event)

        open_email(faculty.email)

        expect(current_email).to be_nil
      end
    end
  end
end