# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# third-party users, it should be done in your "mix.exs" file.

# You can configure your application as:
#
#     config :cryptofund, key: :value
#
# and access this configuration in your application as:
#
#     Application.get_env(:cryptofund, :key)
#
# You can also configure a third-party app:
#
#     config :logger, level: :info
#
# tell logger to load a LoggerFileBackend processes
config :logger,
       backends: [{LoggerFileBackend, :error_log}]

# configuration for the {LoggerFileBackend, :error_log} backend
config :logger,
       :error_log,
       path: "./cf.log",
       level: :info
       #,metadata: [:module, :line, :function]
