require 'openssl'
require 'base64'
require 'digest/md5'
require 'cgi'

module Thumbor
    class CryptoURL
        attr_accessor :computed_key

        def initialize(key)
            Thumbor.key = key
        end

        def computed_key
            (Thumbor.key * 16)[0..15]
        end

        def pad(s)
            s + ("{" * (16 - s.length % 16))
        end

        def calculate_width_and_height(url_parts, options)
            width = options[:width]
            height = options[:height]

            if width and options[:flip]
                width = width * -1
            end
            if height and options[:flop]
                height = height * -1
            end

            if width or height
                width = 0 if not width
                height = 0 if not height
            end

            has_width = width
            has_height = height
            if options[:flip] and not has_width and not has_height
                width = "-0"
                height = '0' if not has_height and not options[:flop]
            end
            if options[:flop] and not has_width and not has_height
                height = "-0"
                width = '0' if not has_width and not options[:flip]
            end

            if width or height
                width = width.to_s
                height = height.to_s
                url_parts.push(width << 'x' << height)
            end
        end

        def calculate_centered_crop(options)
            width = options[:width]
            height = options[:height]
            original_width = options[:original_width]
            original_height = options[:original_height]
            center = options[:center]

            return unless original_width &&
                            original_height &&
                            center &&
                            (width || height)

            unless center.kind_of?(Array) && center.length == 2
                raise 'center must be an array of x,y'
            end

            center_x, center_y = center
            width ||= original_width
            height ||= original_height
            width = width.abs
            height = height.abs
            new_aspect_ratio = width / height.to_f
            original_aspect_ratio = original_width/original_height.to_f

            crop = nil
            # We're going wider, vertical crop
            if new_aspect_ratio > original_aspect_ratio
              # How tall should we be? because new_aspect_ratio is > original_aspect_ratio we can be sure
              # that cropped_height is always less than original_height (original). This is assumed below.
              cropped_height = (original_width / new_aspect_ratio).round
              # Calculate coordinates around center
              top_crop_point = (center_y - (cropped_height * 0.5)).round
              bottom_crop_point = (center_y + (cropped_height * 0.5)).round

              # If we've gone above the top of the image, take all from the bottom
              if top_crop_point < 0
                top_crop_point = 0
                bottom_crop_point = cropped_height
              # If we've gone below the top of the image, take all from the top
              elsif bottom_crop_point > original_height
                top_crop_point = original_height - cropped_height
                bottom_crop_point = original_height
              # Because cropped_height < original_height, top_crop_point and
              # bottom_crop_point will never both be out of bounds
              end

              # Put it together
              crop = [0, top_crop_point, original_width, bottom_crop_point]
            # We're going taller, horizontal crop
            elsif new_aspect_ratio < original_aspect_ratio
              # How wide should we be? because new_aspect_ratio is < original_aspect_ratio we can be sure
              # that cropped_width is always less than original_width (original). This is assumed below.
              cropped_width = (original_height * new_aspect_ratio).round
              # Calculate coordinates around center
              left_crop_point = (center_x - (cropped_width * 0.5)).round
              right_crop_point = (center_x + (cropped_width * 0.5)).round

              # If we've gone beyond the left of the image, take all from the right
              if left_crop_point < 0
                left_crop_point = 0
                right_crop_point = cropped_width
              # If we've gone beyond the right of the image, take all from the left
              elsif right_crop_point > original_width
                left_crop_point = original_width - cropped_width
                right_crop_point = original_width
              # Because cropped_width < original_width, left_crop_point and
              # right_crop_point will never both be out of bounds
              end

              # Put it together
              crop = [left_crop_point, 0, right_crop_point, original_height]
            end

            options[:crop] = crop
        end

        def url_for(options, include_hash = true)
            if not options[:image]
                raise 'image is a required argument.'
            end

            url_parts = Array.new

            if options[:meta]
                url_parts.push('meta')
            end

            calculate_centered_crop(options)

            crop = options[:crop]
            if crop
                crop_left = crop[0]
                crop_top = crop[1]
                crop_right = crop[2]
                crop_bottom = crop[3]

                if crop_left > 0 or crop_top > 0 or crop_bottom > 0 or crop_right > 0
                    url_parts.push(crop_left.to_s << 'x' << crop_top.to_s << ':' << crop_right.to_s << 'x' << crop_bottom.to_s)
                end
            end

            if options[:fit_in]
                url_parts.push('fit-in')
            end

            calculate_width_and_height(url_parts, options)

            if options[:halign] and options[:halign] != :center
                url_parts.push(options[:halign])
            end

            if options[:valign] and options[:valign] != :middle
                url_parts.push(options[:valign])
            end

            if options[:smart]
                url_parts.push('smart')
            end

            if options[:trim]
                trim_options  = ['trim']
                trim_options << options[:trim] unless options[:trim] == true or options[:trim][0] == true
                url_parts.push(trim_options.join(':'))
            end

            if options[:filters] && !options[:filters].empty?
              filter_parts = []
              options[:filters].each do |filter|
                filter_parts.push(filter)
              end

              url_parts.push("filters:#{ filter_parts.join(':') }")
            end

            if include_hash
                image_hash = Digest::MD5.hexdigest(options[:image])
                url_parts.push(image_hash)
            end

            return url_parts.join('/')
        end

        def url_safe_base64(str)
            Base64.encode64(str).gsub('+', '-').gsub('/', '_').gsub!(/[\n]/, '')
        end

        def generate_old(options)
            url = pad(url_for(options))
            cipher = OpenSSL::Cipher::Cipher.new('aes-128-ecb').encrypt
            cipher.key = computed_key
            encrypted = cipher.update(url)
            based = url_safe_base64(encrypted)

            "/#{based}/#{options[:image]}"
        end

        def generate_new(options)
            thumbor_path = ""

            image_options = url_for(options, false)
            thumbor_path << image_options + '/' unless image_options.empty?

            thumbor_path << options[:image]

            if Thumbor.key
                signature = url_safe_base64(OpenSSL::HMAC.digest('sha1', Thumbor.key, thumbor_path))
                thumbor_path.insert(0, "/#{signature}/")
            else 
                thumbor_path.insert(0, "/unsafe/")
            end
            thumbor_path
        end

        def generate(options)
            return generate_old(options) if options[:old]
            generate_new(options)
        end
    end
end
