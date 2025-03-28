import json
import os


def generate_initial_file(data, output_dir):
    def extract_minimal_info(call):
        return {
            "id": call.get("id"),
            "contract": call.get("contract"),
            "function": call.get("function"),
            "depth": call.get("depth"),
            "internal_calls": [extract_minimal_info(c) for c in call.get("internal_calls", [])]
        }

    logs = data.get("logs", {})
    calls = logs.get("calls", [])

    minimal_data = {"calls": [extract_minimal_info(call) for call in calls]}
    with open(os.path.join(output_dir, "initial_search.json"), "w") as f:
        json.dump(minimal_data, f, indent=4)


def generate_flat_detailed_file(data, output_dir):
    flat_list = []

    def flatten_call(call):
        flat_list.append({
            "id": call.get("id"),
            "args": call.get("args"),
            "original_code": call.get("original_code"),
            "description": call.get("description"),
            "return_value": call.get("return_value"),
        })
        for c in call.get("internal_calls", []):
            flatten_call(c)

    logs = data.get("logs", {})
    calls = logs.get("calls", [])

    for call in calls:
        flatten_call(call)

    with open(os.path.join(output_dir, "detailed_information.json"), "w") as f:
        json.dump(flat_list, f, indent=4)


def main():
    # Set the input directory
    input_directory = r"output"

    # Iterate over all JSON files in the directory
    for filename in os.listdir(input_directory):
        if filename.endswith(".json"):  # Process only JSON files
            input_file_path = os.path.join(input_directory, filename)

            # Load JSON data from the file
            with open(input_file_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            # Extract the base name of the file without the extension
            base_name = os.path.splitext(filename)[0]

            # Create output directory under "out"
            output_dir = os.path.join("out", base_name)
            if not os.path.exists(output_dir):
                os.makedirs(output_dir)

            # Generate the output files
            print(f"Processing file: {filename}")
            generate_initial_file(data, output_dir)
            generate_flat_detailed_file(data, output_dir)

            print(f"Files generated for '{filename}' in directory: '{output_dir}'")

if __name__ == "__main__":
    main()
