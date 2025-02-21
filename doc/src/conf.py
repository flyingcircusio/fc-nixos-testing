# -*- coding: utf-8 -*-
#
# -- General configuration -----------------------------------------------------

# Add any Sphinx extension module names here, as strings. They can be extensions
# coming with Sphinx (named 'sphinx.ext.*') or your custom ones.
extensions = ["myst_parser", "sphinx.ext.intersphinx"]

import os

# The version info for the project you're documenting, acts as replacement for
# {{ version }} and {{ release }}, also used in various other places throughout the
# built documents.
#
# The short X.Y version.
version = os.environ.get("version", "2023.dev")
release = os.environ.get("branch")

# General information about the project.
project = "Flying Circus Platform"
year = version[0:4]
copyright = "Flying Circus Internet Operations GmbH"
master_doc = "master"

# Add any paths that contain templates here, relative to this directory.
templates_path = ["_templates"]

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# -- Options for HTML output ---------------------------------------------------

# The theme to use for HTML and HTML Help pages.  Major themes that come with
# Sphinx are currently 'default' and 'sphinxdoc'.
import furo

html_theme = "furo"

html_theme_options = {
    "sidebar_hide_name": True,
    "dark_logo": "RZ_FC-Logo_RGB_INV-BL_100-1080.svg",
    "dark_css_variables": {
        "color-brand-content": "#a9d2b6",
        "color-brand-primary": "#a9d2b6",
        "color-highlight-on-target": "#666",
        "color-headings": "#fff",
    },
    "light_logo": "RZ_FC-Logo_RGB_100-1080.svg",
    "light_css_variables": {
        "color-brand-content": "#52a46c",
        "color-brand-primary": "#52a46c",
        "color-highlight-on-target": "#f2f5f8",
        "color-headings": "#002855",
        "font-stack": "Fira Sans, Helvetica, Arial, sans-serif",
    },
}

# The name for this set of Sphinx documents.  If None, it defaults to
# "<project> v<release> documentation".
# html_title = None

# A shorter title for the navigation bar.  Default is the same as html_title.
# html_short_title = project

# The name of an image file (relative to this directory) to place at the top
# of the sidebar.
# html_logo = "images/flying-circus-logo.png"

# The name of an image file (within the static path) to use as favicon of the
# docs.  This file should be a Windows icon file (.ico) being 16x16 or 32x32
# pixels large.
# html_favicon = 'favicon.ico'

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
html_static_path = ["_static"]

# If not '', a 'Last updated on:' timestamp is inserted at every page bottom,
# using the given strftime format.
html_last_updated_fmt = None

# Custom sidebar templates, maps document names to template names.
# html_sidebars = {}

# Additional templates that should be rendered to pages, maps page names to
# template names.
# html_additional_pages = {}

# If false, no module index is generated.
html_use_modindex = False

# If false, no index is generated.
# html_use_index = True

# If true, the index is split into individual pages for each letter.
# html_split_index = False

# If true, links to the reST sources are added to the pages.
html_show_sourcelink = False

# Output file base name for HTML help builder.
htmlhelp_basename = "flyingcircus"

# -- Options for extensions ----------------------------------------------------

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "replacements",
    "smartquotes",
    "substitution",
    "linkify",
]
myst_heading_anchors = 3
myst_substitutions = {"release": release, "version": version}
myst_all_links_external = True


def setup(app):
    app.add_css_file("flyingcircus.css")
