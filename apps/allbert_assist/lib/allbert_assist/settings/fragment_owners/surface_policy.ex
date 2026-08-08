defmodule AllbertAssist.Settings.FragmentOwners.SurfacePolicy do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "surface_policy.defaults.max_rows" => %{
      default: 25,
      max: 1000,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "surface_policy.defaults.raw_requires_affordance" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "surface_policy.defaults.redaction_profile" => %{
      allowed_values: ["standard", "strict"],
      default: "standard",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "surface_policy.defaults.render_mode" => %{
      allowed_values: ["assistant_summary"],
      default: "assistant_summary",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "surface_policy.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "surface_policy" => %{
      "defaults" => %{
        "max_rows" => 25,
        "raw_requires_affordance" => true,
        "redaction_profile" => "standard",
        "render_mode" => "assistant_summary"
      },
      "schema_version" => 1,
      "surfaces" => %{
        "cli" => %{
          "intent_coverage" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_descriptors" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_review" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_channels" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_model_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_provider_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_settings" => %{
            "max_rows" => 1000,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "model_doctor" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "settings_doctor" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          }
        },
        "live_view" => %{
          "intent_coverage" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_descriptors" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_review" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_model_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_provider_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "model_doctor" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          }
        },
        "tui" => %{
          "intent_coverage" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_descriptors" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "intent_list_review" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_channels" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_model_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_provider_profiles" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "list_settings" => %{
            "max_rows" => 1000,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "model_doctor" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          },
          "settings_doctor" => %{
            "max_rows" => 100,
            "raw_requires_affordance" => true,
            "redaction_profile" => "standard",
            "render_mode" => "operator_report"
          }
        }
      }
    }
  }
  @safe_write_keys [
    "surface_policy.schema_version",
    "surface_policy.defaults.render_mode",
    "surface_policy.defaults.redaction_profile",
    "surface_policy.defaults.max_rows",
    "surface_policy.defaults.raw_requires_affordance",
    "surface_policy.surfaces.*.*.render_mode",
    "surface_policy.surfaces.*.*.redaction_profile",
    "surface_policy.surfaces.*.*.max_rows",
    "surface_policy.surfaces.*.*.raw_requires_affordance"
  ]
  @safe_write_rows [
    {220, "surface_policy.schema_version"},
    {221, "surface_policy.defaults.render_mode"},
    {222, "surface_policy.defaults.redaction_profile"},
    {223, "surface_policy.defaults.max_rows"},
    {224, "surface_policy.defaults.raw_requires_affordance"},
    {225, "surface_policy.surfaces.*.*.render_mode"},
    {226, "surface_policy.surfaces.*.*.redaction_profile"},
    {227, "surface_policy.surfaces.*.*.max_rows"},
    {228, "surface_policy.surfaces.*.*.raw_requires_affordance"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:surface_policy",
      owner: "surface_policy",
      source: :core,
      group: "surface_policy",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Surface Policy"}
    })
  end

  @impl true
  def dynamic_default_keys do
    [
      "surface_policy.surfaces.*.*.render_mode",
      "surface_policy.surfaces.*.*.redaction_profile",
      "surface_policy.surfaces.*.*.max_rows",
      "surface_policy.surfaces.*.*.raw_requires_affordance"
    ]
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
