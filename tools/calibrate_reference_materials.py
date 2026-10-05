"""Blender node adjustments for the Horzine bake under KF2 world lighting."""

def calibrate(material):
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    shader = nodes.get('Principled BSDF')
    if shader is None or not shader.inputs['Base Color'].is_linked:
        return
    original = shader.inputs['Base Color'].links[0].from_socket
    if material.name.startswith('Skin | scarred'):
        scar = nodes.new('ShaderNodeAttribute')
        scar.attribute_name = 'HealedScar'
        broad = nodes.new('ShaderNodeMath')
        broad.operation = 'POWER'
        broad.inputs[1].default_value = .45
        links.new(scar.outputs['Fac'], broad.inputs[0])
        tone = nodes.new('ShaderNodeValToRGB')
        tone.color_ramp.elements[0].position = .05
        tone.color_ramp.elements[0].color = (.065, .018, .016, 1)
        tone.color_ramp.elements[1].position = .88
        tone.color_ramp.elements[1].color = (.37, .185, .14, 1)
        links.new(scar.outputs['Fac'], tone.inputs[0])
        mix = nodes.new('ShaderNodeMixRGB')
        links.new(broad.outputs[0], mix.inputs[0])
        links.new(original, mix.inputs[1])
        links.new(tone.outputs[0], mix.inputs[2])
        links.new(mix.outputs[0], shader.inputs['Base Color'])
        bump = nodes.new('ShaderNodeBump')
        bump.inputs['Distance'].default_value = .09
        bump.inputs['Strength'].default_value = .65
        links.new(scar.outputs['Fac'], bump.inputs['Height'])
        if shader.inputs['Normal'].is_linked:
            links.new(shader.inputs['Normal'].links[0].from_socket, bump.inputs['Normal'])
        links.new(bump.outputs[0], shader.inputs['Normal'])
    elif material.name.startswith(('Glove | aged charcoal', 'Glove | burnished')):
        # Keep the authored wear fields; lower the broad olive wash.
        tint = nodes.new('ShaderNodeMixRGB')
        tint.blend_type = 'MULTIPLY'
        tint.inputs[0].default_value = 1
        tint.inputs[2].default_value = (.68, .70, .72, 1)
        links.new(original, tint.inputs[1])
        floor = nodes.new('ShaderNodeMixRGB')
        floor.blend_type = 'ADD'
        floor.inputs[0].default_value = 1
        floor.inputs[2].default_value = (.007, .007, .0065, 1)
        links.new(tint.outputs[0], floor.inputs[1])
        links.new(floor.outputs[0], shader.inputs['Base Color'])
