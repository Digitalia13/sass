require 'sass/script/css_parser'

module Sass
  module SCSS
    # A parser for a static SCSS tree.
    # Parses with SCSS extensions, like nested rules and parent selectors,
    # but without dynamic SassScript.
    # This is useful for e.g. \{#parse\_selector parsing selectors}
    # after resolving the interpolation.
    class StaticParser < Parser
      # Parses the text as a selector.
      #
      # @param filename [String, nil] The file in which the selector appears,
      #   or nil if there is no such file.
      #   Used for error reporting.
      # @return [Selector::CommaSequence] The parsed selector
      # @raise [Sass::SyntaxError] if there's a syntax error in the selector
      def parse_selector
        init_scanner!
        seq = expr!(:selector_comma_sequence)
        expected("selector") unless @scanner.eos?
        seq.line = @line
        seq.filename = @filename
        seq
      end

      # Parses a static at-root query.
      #
      # @return [(Symbol, Array<String>)] The type of the query
      #   (`:with` or `:without`) and the values that are being filtered.
      # @raise [Sass::SyntaxError] if there's a syntax error in the query,
      #   or if it doesn't take up the entire input string.
      def parse_static_at_root_query
        init_scanner!
        tok!(/\(/); ss
        type = tok!(/\b(without|with)\b/).to_sym; ss
        tok!(/:/); ss
        directives = expr!(:at_root_directive_list); ss
        tok!(/\)/)
        expected("@at-root query list") unless @scanner.eos?
        return type, directives
      end

      private

      def moz_document_function
        val = tok(URI) || tok(URL_PREFIX) || tok(DOMAIN) || function(!:allow_var)
        return unless val
        ss
        [val]
      end

      def variable; nil; end
      def script_value; nil; end
      def interpolation; nil; end
      def var_expr; nil; end
      def interp_string; (s = tok(STRING)) && [s]; end
      def interp_uri; (s = tok(URI)) && [s]; end
      def interp_ident(ident = IDENT); (s = tok(ident)) && [s]; end
      def use_css_import?; true; end

      def special_directive(name, start_pos)
        return unless %w[media import charset -moz-document].include?(name)
        super
      end

      def selector_comma_sequence
        sel = _selector
        return unless sel
        selectors = [sel]
        ws = ''
        while tok(/,/)
          ws << str {ss}
          if (sel = _selector)
            selectors << sel
            if ws.include?("\n")
              selectors[-1] = Selector::Sequence.new(["\n"] + selectors.last.members)
            end
            ws = ''
          end
        end
        Selector::CommaSequence.new(selectors)
      end

      def selector
        sel = _selector
        return unless sel
        sel.to_a
      end

      def _selector
        # The combinator here allows the "> E" hack
        val = combinator || simple_selector_sequence
        return unless val
        nl = str {ss}.include?("\n")
        res = []
        res << val
        res << "\n" if nl

        while (val = combinator || simple_selector_sequence)
          res << val
          res << "\n" if str {ss}.include?("\n")
        end
        Selector::Sequence.new(res.compact)
      end

      def combinator
        tok(PLUS) || tok(GREATER) || tok(TILDE) || reference_combinator
      end

      def reference_combinator
        return unless tok(/\//)
        res = ['/']
        ns, name = expr!(:qualified_name)
        res << ns << '|' if ns
        res << name << tok!(/\//)
        res = res.flatten
        res = res.join '' if res.all? {|e| e.is_a?(String)}
        res
      end

      def simple_selector_sequence
        # Returning expr by default allows for stuff like
        # http://www.w3.org/TR/css3-animations/#keyframes-

        start_pos = source_position
        e = element_name || id_selector ||
          class_selector || placeholder_selector || attrib || pseudo ||
          parent_selector || interpolation_selector
        return expr(!:allow_var) unless e
        res = [e]

        # The tok(/\*/) allows the "E*" hack
        while (v = id_selector || class_selector || placeholder_selector ||
                   attrib || pseudo || interpolation_selector ||
                   (tok(/\*/) && Selector::Universal.new(nil)))
          res << v
        end

        pos = @scanner.pos
        line = @line
        if (sel = str? {simple_selector_sequence})
          @scanner.pos = pos
          @line = line
          begin
            # If we see "*E", don't force a throw because this could be the
            # "*prop: val" hack.
            expected('"{"') if res.length == 1 && res[0].is_a?(Selector::Universal)
            throw_error {expected('"{"')}
          rescue Sass::SyntaxError => e
            e.message << "\n\n\"#{sel}\" may only be used at the beginning of a compound selector."
            raise e
          end
        end

        Selector::SimpleSequence.new(res, tok(/!/), range(start_pos))
      end

      def parent_selector
        return unless tok(/&/)
        Selector::Parent.new(interp_ident(NAME) || [])
      end

      def class_selector
        return unless tok(/\./)
        @expected = "class name"
        Selector::Class.new(merge(expr!(:interp_ident)))
      end

      def id_selector
        return unless tok(/#(?!\{)/)
        @expected = "id name"
        Selector::Id.new(merge(expr!(:interp_name)))
      end

      def placeholder_selector
        return unless tok(/%/)
        @expected = "placeholder name"
        Selector::Placeholder.new(merge(expr!(:interp_ident)))
      end

      def element_name
        ns, name = Sass::Util.destructure(qualified_name(:allow_star_name))
        return unless ns || name

        if name == '*'
          Selector::Universal.new(merge(ns))
        else
          Selector::Element.new(merge(name), merge(ns))
        end
      end

      def qualified_name(allow_star_name = false)
        name = interp_ident || tok(/\*/) || (tok?(/\|/) && "")
        return unless name
        return nil, name unless tok(/\|/)

        return name, expr!(:interp_ident) unless allow_star_name
        @expected = "identifier or *"
        return name, interp_ident || tok!(/\*/)
      end

      def interpolation_selector
        if (script = interpolation)
          Selector::Interpolation.new(script)
        end
      end

      def attrib
        return unless tok(/\[/)
        ss
        ns, name = attrib_name!
        ss

        op = tok(/=/) ||
             tok(INCLUDES) ||
             tok(DASHMATCH) ||
             tok(PREFIXMATCH) ||
             tok(SUFFIXMATCH) ||
             tok(SUBSTRINGMATCH)
        if op
          @expected = "identifier or string"
          ss
          val = interp_ident || expr!(:interp_string)
          ss
        end
        flags = interp_ident || interp_string
        tok!(/\]/)

        Selector::Attribute.new(merge(name), merge(ns), op, merge(val), merge(flags))
      end

      def attrib_name!
        if (name_or_ns = interp_ident)
          # E, E|E
          if tok(/\|(?!=)/)
            ns = name_or_ns
            name = interp_ident
          else
            name = name_or_ns
          end
        else
          # *|E or |E
          ns = [tok(/\*/) || ""]
          tok!(/\|/)
          name = expr!(:interp_ident)
        end
        return ns, name
      end

      def pseudo
        s = tok(/::?/)
        return unless s
        @expected = "pseudoclass or pseudoelement"
        name = expr!(:interp_ident)
        if tok(/\(/)
          ss
          arg = expr!(:pseudo_arg)
          while tok(/,/)
            arg << ',' << str {ss}
            arg.concat expr!(:pseudo_arg)
          end
          tok!(/\)/)
        end
        Selector::Pseudo.new(s == ':' ? :class : :element, merge(name), merge(arg))
      end

      def pseudo_arg
        # In the CSS spec, every pseudo-class/element either takes a pseudo
        # expression or a selector comma sequence as an argument. However, we
        # don't want to have to know which takes which, so we handle both at
        # once.
        #
        # However, there are some ambiguities between the two. For instance, "n"
        # could start a pseudo expression like "n+1", or it could start a
        # selector like "n|m". In order to handle this, we must regrettably
        # backtrack.
        expr, sel = nil, nil
        pseudo_err = catch_error do
          expr = pseudo_expr
          next if tok?(/[,)]/)
          expr = nil
          expected '")"'
        end

        return expr if expr
        sel_err = catch_error {sel = selector}
        return sel if sel
        rethrow pseudo_err if pseudo_err
        rethrow sel_err if sel_err
        nil
      end

      def pseudo_expr_token
        tok(PLUS) || tok(/[-*]/) || tok(NUMBER) || interp_string || tok(IDENT) || interpolation
      end

      def pseudo_expr
        e = pseudo_expr_token
        return unless e
        res = [e, str {ss}]
        while (e = pseudo_expr_token)
          res << e << str {ss}
        end
        res
      end

      @sass_script_parser = Class.new(Sass::Script::CssParser)
      @sass_script_parser.send(:include, ScriptParser)
    end
  end
end
