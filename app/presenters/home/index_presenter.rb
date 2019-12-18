module Home
  class IndexPresenter < ApplicationPresenter
    def initialize(view_context, school)
      super(view_context)

      @school = school
    end

    def page_title
      @school.name
    end

    alias school_name page_title

    def courses
      @school.courses.where(featured: true)
    end

    def cover_image
      view.url_for(@school.cover_image) if @school.cover_image.attached?
    end

    def course_thumbnail(course)
      view.url_for(course.thumbnail) if course.thumbnail.attached?
    end
  end
end